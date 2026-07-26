defmodule RealtimeGateway.ConversationChannelReceiptsTest do
  @moduledoc """
  Read-receipt reciprocity on the LIVE tick (`receipt_updated`). The emit gate is resolved once at join
  (read_receipts_enabled for the reader, and — for a DIRECT chat — the peer). A reader who disabled receipts
  emits none (emit half); if the DM peer disabled, the reader also emits none (delivery half — the peer
  wouldn't receive them). Delivered receipts (single tick) are NEVER gated. The load-path read_by_count filter
  is proven separately in the message_service postgres suite.

  Docker-free: placeholder socket + persistence off; only the privacy + conversation lookups are stubbed.
  """
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  @endpoint RealtimeGateway.TestEndpoint

  defmodule UserStub do
    def start_link, do: Agent.start_link(fn -> %{"reader" => true, "peer" => true} end, name: __MODULE__)
    def set(user, v), do: Agent.update(__MODULE__, &Map.put(&1, user, v))

    def get_privacy(%{"user_id" => uid}) do
      {:ok, %{read_receipts_enabled: Agent.get(__MODULE__, &Map.get(&1, uid, true))}}
    end
  end

  defmodule ConvStub do
    # A DIRECT conversation of {reader, peer}; never blocked (so dm_blocked/typing doesn't interfere here).
    def get_conversation(_attrs),
      do: {:ok, %{type: "direct", participants: [%{user_id: "reader"}, %{user_id: "peer"}]}}

    def direct_peer_blocked?(_attrs), do: {:ok, %{blocked: false}}
    # inbox_rows / shares aren't needed here (the inbox fan-out is fire-and-forget); default to harmless.
    def inbox_rows(_attrs), do: {:ok, %{rows: []}}
  end

  # The persist leg (mark_read/mark_delivered) always runs — the read is durable regardless of the live tick.
  defmodule MsgStub do
    def mark_read(_attrs), do: {:ok, %{status: "read"}}
    def mark_delivered(_attrs), do: {:ok, %{status: "delivered"}}
  end

  setup do
    start_supervised!(%{id: UserStub, start: {UserStub, :start_link, []}})
    prev = %{
      u: Application.get_env(:shared_infra, :user_client_adapter),
      c: Application.get_env(:shared_infra, :conversation_client_adapter),
      m: Application.get_env(:shared_infra, :message_client_adapter),
      persist: Application.get_env(:conversation_service, :conversation_persistence)
    }

    Application.put_env(:shared_infra, :user_client_adapter, UserStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)
    Application.put_env(:conversation_service, :conversation_persistence, false)

    on_exit(fn ->
      restore(:shared_infra, :user_client_adapter, prev.u)
      restore(:shared_infra, :conversation_client_adapter, prev.c)
      restore(:shared_infra, :message_client_adapter, prev.m)
      restore(:conversation_service, :conversation_persistence, prev.persist)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, v), do: Application.put_env(app, key, v)

  defp join_channel do
    RealtimeGateway.UserSocket
    |> socket("user_socket:reader", %{current_user_id: "reader", user_id: "reader"})
    |> subscribe_and_join(RealtimeGateway.ConversationChannel, "conversation:dm_1", %{})
  end

  test "both parties have receipts ON → the live read tick IS broadcast" do
    UserStub.set("reader", true)
    UserStub.set("peer", true)
    {:ok, _, socket} = join_channel()

    ref = push(socket, "message_read", %{"message_id" => "m1"})
    assert_reply(ref, :ok)
    assert_broadcast("receipt_updated", %{receipt_type: "read"})
  end

  test "READER disabled → the live read tick is NOT broadcast (emit half)" do
    UserStub.set("reader", false)
    UserStub.set("peer", true)
    {:ok, _, socket} = join_channel()

    ref = push(socket, "message_read", %{"message_id" => "m1"})
    assert_reply(ref, :ok)
    refute_broadcast("receipt_updated", _)
  end

  test "DM PEER disabled → the reader's live read tick is NOT broadcast (delivery half)" do
    UserStub.set("reader", true)
    UserStub.set("peer", false)
    {:ok, _, socket} = join_channel()

    ref = push(socket, "message_read", %{"message_id" => "m1"})
    assert_reply(ref, :ok)
    refute_broadcast("receipt_updated", _)
  end

  test "DELIVERED receipts are NEVER gated (even when the reader disabled read receipts)" do
    UserStub.set("reader", false)
    {:ok, _, socket} = join_channel()

    ref = push(socket, "message_delivered", %{"message_id" => "m1"})
    assert_reply(ref, :ok)
    assert_broadcast("receipt_updated", %{receipt_type: "delivered"})
  end
end
