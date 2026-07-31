defmodule ApiGatewayWeb.V1.CallEndNotifyTest do
  @moduledoc """
  POST /v1/calls/:id/end must tell the OTHER party (`call:ended`) — the socket hangup's second half, which
  the /v1 path was missing: without it an SDK peer sits "connected" forever after the other side hangs up.
  Same stub/PubSub pattern as CallAcceptRejectTest.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.V1.CallController

  @call_id "11111111-1111-4111-8111-111111111111"
  @caller "22222222-2222-4222-8222-222222222222"
  @callee "33333333-3333-4333-8333-333333333333"
  @stranger "44444444-4444-4444-8444-444444444444"
  @app_id "55555555-5555-4555-8555-555555555555"

  defmodule ConvStub do
    def start_link, do: Agent.start_link(fn -> %{kind: "direct", log: []} end, name: __MODULE__)
    def set_kind(kind), do: Agent.update(__MODULE__, &Map.put(&1, :kind, kind))
    def log, do: Agent.get(__MODULE__, & &1.log) |> Enum.reverse()

    def get_call(%{"call_id" => call_id}) do
      {:ok,
       %{
         id: call_id,
         caller_id: "22222222-2222-4222-8222-222222222222",
         callee_id: "33333333-3333-4333-8333-333333333333",
         room_name: "room-abc",
         status: "accepted",
         kind: Agent.get(__MODULE__, & &1.kind),
         type: "voice"
       }}
    end

    def mark_call_ended(attrs) do
      record({:ended, attrs})
      {:ok, %{id: attrs["call_id"], status: "ended"}}
    end

    def leave_group_call(attrs) do
      record({:left, attrs})
      {:ok, %{}}
    end

    def call_participant?(_attrs), do: {:ok, %{authorized: true}}

    defp record(e), do: Agent.update(__MODULE__, fn s -> %{s | log: [e | s.log]} end)
  end

  setup do
    start_supervised!(%{id: ConvStub, start: {ConvStub, :start_link, []}})
    prev = Application.get_env(:shared_infra, :conversation_client_adapter)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:shared_infra, :conversation_client_adapter, prev),
        else: Application.delete_env(:shared_infra, :conversation_client_adapter)
    end)

    :ok
  end

  defp end_call(user_id) do
    :post
    |> conn("/v1/calls/#{@call_id}/end", %{})
    |> assign(:v1_app_id, @app_id)
    |> assign(:v1_actor, :end_user)
    |> assign(:v1_user_id, user_id)
    |> CallController.end_call(%{"id" => @call_id})
  end

  test "the CALLER ends → the CALLEE is told (call:ended), and the shared ended path ran" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@callee}")

    conn = end_call(@caller)

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ended"}

    assert_receive %Phoenix.Socket.Broadcast{event: "call:ended", payload: %{call_id: @call_id}},
                   1000

    # mark_call_ended is the fn whose CallStore transition emits the call.ended webhook (CallWebhooksTest).
    assert {:ended, %{"call_id" => @call_id}} in ConvStub.log()
  end

  test "the CALLEE ends → the CALLER is told" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@caller}")

    assert end_call(@callee).status == 200

    assert_receive %Phoenix.Socket.Broadcast{event: "call:ended", payload: %{call_id: @call_id}},
                   1000
  end

  test "a NON-seat user → opaque 404, no transition, no broadcast" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@caller}")
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@callee}")

    assert end_call(@stranger).status == 404
    assert ConvStub.log() == []
    refute_receive %Phoenix.Socket.Broadcast{}, 200
  end

  test "a GROUP call is a LEAVE — no call:ended broadcast (its lifecycle has its own events)" do
    ConvStub.set_kind("group")
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@caller}")
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@callee}")

    conn = end_call(@caller)
    assert Jason.decode!(conn.resp_body) == %{"status" => "left"}
    refute_receive %Phoenix.Socket.Broadcast{event: "call:ended"}, 300
  end
end
