defmodule RealtimeGateway.ConversationChannelBlockTest do
  @moduledoc """
  Typing/"viewing" suppression for a blocked DIRECT peer — the blocker must never see "X is typing…" from
  someone they blocked. `dm_blocked` is resolved ONCE at join (ConversationClient.direct_peer_blocked?) and
  gates the ephemeral broadcasts. Docker-free: a placeholder socket + conversation persistence OFF (join is
  allowed without a DB); only the block check is stubbed.
  """
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  @endpoint RealtimeGateway.TestEndpoint

  defmodule ConvStub do
    def start_link, do: Agent.start_link(fn -> %{blocked: false} end, name: __MODULE__)
    def set_blocked(v), do: Agent.update(__MODULE__, &Map.put(&1, :blocked, v))
    def direct_peer_blocked?(_attrs), do: {:ok, %{blocked: Agent.get(__MODULE__, & &1.blocked)}}
  end

  setup do
    start_supervised!(%{id: ConvStub, start: {ConvStub, :start_link, []}})
    prev_conv = Application.get_env(:shared_infra, :conversation_client_adapter)
    prev_persist = Application.get_env(:conversation_service, :conversation_persistence)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:conversation_service, :conversation_persistence, false)

    on_exit(fn ->
      restore(:shared_infra, :conversation_client_adapter, prev_conv)
      restore(:conversation_service, :conversation_persistence, prev_persist)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, v), do: Application.put_env(app, key, v)

  defp join_channel do
    RealtimeGateway.UserSocket
    |> socket("user_socket:u1", %{current_user_id: "u1", user_id: "u1"})
    |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:dm_1", %{})
  end

  test "BLOCKED DM: typing is NOT broadcast — but the sender still gets its own :ok reply" do
    ConvStub.set_blocked(true)
    {:ok, _reply, socket} = join_channel()

    ref = push(socket, "typing:start", %{})
    assert_reply(ref, :ok)
    refute_broadcast("typing_started", _)
  end

  test "NOT blocked: typing IS broadcast (control)" do
    ConvStub.set_blocked(false)
    {:ok, _reply, socket} = join_channel()

    ref = push(socket, "typing:start", %{})
    assert_reply(ref, :ok)
    assert_broadcast("typing_started", %{user_id: "u1"})
  end
end
