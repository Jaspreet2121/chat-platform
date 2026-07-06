defmodule RealtimeGateway.CallSignalingMockClient do
  @moduledoc """
  In-memory stand-in for the call surface of `SharedInfra.ConversationClient` (one ringing call at a time),
  backed by a named Agent. Records every call so tests can assert the store was driven; returns atom-keyed
  maps (like the in-process CallStore) which `CallSignaling.cget/2` reads. Not a full behaviour impl — the
  dispatcher resolves the adapter at runtime, so only the call functions the signaling path uses are here.
  """
  def start_link, do: Agent.start_link(fn -> %{call: nil, log: []} end, name: __MODULE__)
  def reset, do: Agent.update(__MODULE__, fn _ -> %{call: nil, log: []} end)
  def log, do: Agent.get(__MODULE__, & &1.log) |> Enum.reverse()

  def create_call(attrs) do
    call = %{
      id: "call_1",
      room_name: "room_1",
      status: "ringing",
      caller_id: attrs["caller_id"],
      callee_id: attrs["callee_id"],
      type: attrs["type"],
      conversation_id: attrs["conversation_id"]
    }

    Agent.update(__MODULE__, fn s -> %{s | call: call, log: [{:create, attrs} | s.log]} end)
    {:ok, call}
  end

  def get_call(%{"call_id" => id}) do
    case Agent.get(__MODULE__, & &1.call) do
      %{id: ^id} = call -> {:ok, call}
      _ -> {:error, :call_not_found}
    end
  end

  def mark_call_answered(attrs), do: transition(:answer, "accepted", attrs)
  def mark_call_declined(attrs), do: transition(:decline, "declined", attrs)
  def mark_call_missed(attrs), do: transition(:miss, "missed", attrs)
  def mark_call_ended(attrs), do: transition(:end, "ended", attrs)

  defp transition(op, status, attrs) do
    Agent.get_and_update(__MODULE__, fn s ->
      call = if s.call, do: %{s.call | status: status}, else: nil
      {{:ok, call}, %{s | call: call, log: [{op, attrs} | s.log]}}
    end)
  end
end

defmodule RealtimeGateway.CallCaptureEndpoint do
  @moduledoc "Fake channel endpoint: forwards every broadcast to the registered test pid."
  def broadcast(topic, event, payload) do
    case Application.get_env(:realtime_gateway, :call_test_pid) do
      pid when is_pid(pid) -> send(pid, {:broadcast, topic, event, payload})
      _ -> :ok
    end

    :ok
  end
end

defmodule RealtimeGateway.CallSignalingTest do
  @moduledoc """
  Docker-free unit tests for the Phase-1 call ring control plane (`RealtimeGateway.CallSignaling`), driven
  directly with a fake socket + capture endpoint + mock conversation client — no DB, no Kafka (push stays
  off by default). Covers: invite persists + rings the callee; accept/reject/hangup transition + notify the
  right party; and ownership auth rejects a non-participant and the wrong role.
  """
  use ExUnit.Case, async: false

  alias RealtimeGateway.CallSignaling
  alias RealtimeGateway.CallSignalingMockClient, as: Mock

  @caller "11111111-1111-1111-1111-111111111111"
  @callee "22222222-2222-2222-2222-222222222222"
  @stranger "33333333-3333-3333-3333-333333333333"

  setup do
    start_supervised!(%{id: Mock, start: {Mock, :start_link, []}})
    Mock.reset()

    prev = Application.get_env(:shared_infra, :conversation_client_adapter)
    Application.put_env(:shared_infra, :conversation_client_adapter, Mock)
    Application.put_env(:realtime_gateway, :call_test_pid, self())

    on_exit(fn ->
      if prev,
        do: Application.put_env(:shared_infra, :conversation_client_adapter, prev),
        else: Application.delete_env(:shared_infra, :conversation_client_adapter)

      Application.delete_env(:realtime_gateway, :call_test_pid)
    end)

    :ok
  end

  # Fake socket: CallSignaling only touches `.assigns.current_user_id` and `.endpoint`.
  defp socket(user_id), do: %{assigns: %{current_user_id: user_id}, endpoint: RealtimeGateway.CallCaptureEndpoint}

  defp invite! do
    assert {:reply, {:ok, %{call_id: call_id, room: room}}, _} =
             CallSignaling.handle_event(
               "call:invite",
               %{"callee_id" => @callee, "type" => "video"},
               socket(@caller)
             )

    # The invite rings the CALLEE over their user topic with the room + caller identity.
    assert_receive {:broadcast, topic, "call:incoming", payload}
    assert topic == "user:#{@callee}"
    assert payload.call_id == call_id
    assert payload.room == room
    assert payload.type == "video"
    assert payload.caller_id == @caller

    {call_id, room}
  end

  test "invite persists a ringing call and rings the callee" do
    {call_id, _room} = invite!()

    assert call_id == "call_1"
    assert [{:create, attrs} | _] = Mock.log()
    assert attrs["caller_id"] == @caller
    assert attrs["callee_id"] == @callee
    assert attrs["type"] == "video"
  end

  test "inviting yourself is rejected without persisting" do
    assert {:reply, {:error, %{code: "call.invalid_callee"}}, _} =
             CallSignaling.handle_event(
               "call:invite",
               %{"callee_id" => @caller, "type" => "voice"},
               socket(@caller)
             )

    assert Mock.log() == []
  end

  test "callee accept transitions to accepted and notifies the caller with the room" do
    {call_id, room} = invite!()

    assert {:reply, {:ok, %{call_id: ^call_id}}, _} =
             CallSignaling.handle_event("call:accept", %{"call_id" => call_id}, socket(@callee))

    assert_receive {:broadcast, "user:" <> caller, "call:accepted", payload}
    assert caller == @caller
    assert payload.room == room
    assert Enum.any?(Mock.log(), &match?({:answer, _}, &1))
  end

  test "callee reject transitions to declined and notifies the caller" do
    {call_id, _room} = invite!()

    assert {:reply, {:ok, _}, _} =
             CallSignaling.handle_event("call:reject", %{"call_id" => call_id}, socket(@callee))

    assert_receive {:broadcast, "user:" <> caller, "call:rejected", %{call_id: ^call_id}}
    assert caller == @caller
    assert Enum.any?(Mock.log(), &match?({:decline, _}, &1))
  end

  test "caller hangup notifies the OTHER party (callee)" do
    {call_id, _room} = invite!()

    assert {:reply, {:ok, _}, _} =
             CallSignaling.handle_event("call:hangup", %{"call_id" => call_id}, socket(@caller))

    assert_receive {:broadcast, "user:" <> other, "call:ended", %{call_id: ^call_id}}
    assert other == @callee
    assert Enum.any?(Mock.log(), &match?({:end, _}, &1))
  end

  test "a non-participant cannot accept (ownership auth → call.forbidden)" do
    {call_id, _room} = invite!()

    assert {:reply, {:error, %{code: "call.forbidden"}}, _} =
             CallSignaling.handle_event("call:accept", %{"call_id" => call_id}, socket(@stranger))

    # No transition happened.
    refute Enum.any?(Mock.log(), &match?({:answer, _}, &1))
  end

  test "the caller cannot accept their own call (accept is callee-only)" do
    {call_id, _room} = invite!()

    assert {:reply, {:error, %{code: "call.forbidden"}}, _} =
             CallSignaling.handle_event("call:accept", %{"call_id" => call_id}, socket(@caller))
  end

  test "acting on an unknown call id → call.not_found" do
    assert {:reply, {:error, %{code: "call.not_found"}}, _} =
             CallSignaling.handle_event("call:hangup", %{"call_id" => "nope"}, socket(@caller))
  end

  test "an unknown call:* event → call.invalid_event" do
    assert {:reply, {:error, %{code: "call.invalid_event"}}, _} =
             CallSignaling.handle_event("call:teleport", %{}, socket(@caller))
  end
end
