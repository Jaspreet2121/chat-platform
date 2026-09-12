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
    def start_link,
      do: Agent.start_link(fn -> %{"reader" => true, "peer" => true} end, name: __MODULE__)

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
    # Records what was actually persisted: the batch handler must write one receipt PER id, with the
    # SOCKET's identity, not whatever the payload claims.
    def start_link, do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def persisted, do: Agent.get(__MODULE__, &Enum.reverse/1)

    defp record(attrs, status) do
      if Process.whereis(__MODULE__) do
        Agent.update(__MODULE__, &[Map.put(attrs, "status", status) | &1])
      end
    end

    def mark_read(attrs) do
      record(attrs, "read")
      {:ok, %{status: "read"}}
    end

    def mark_delivered(attrs) do
      record(attrs, "delivered")
      {:ok, %{status: "delivered"}}
    end
  end

  setup do
    start_supervised!(%{id: UserStub, start: {UserStub, :start_link, []}})
    start_supervised!(%{id: MsgStub, start: {MsgStub, :start_link, []}})

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

  # --- BATCHED RECEIPTS: one push, N receipts ------------------------------------------------------

  describe "messages_read / messages_delivered (batch)" do
    test "ONE push persists a receipt for EVERY id — the loop covers the whole batch" do
      {:ok, _, socket} = join_channel()
      ids = for i <- 1..25, do: "m#{i}"

      ref = push(socket, "messages_read", %{"message_ids" => ids})
      assert_reply(ref, :ok, %{accepted: 25})

      persisted = MsgStub.persisted() |> Enum.filter(&(&1["status"] == "read"))

      assert Enum.map(persisted, & &1["message_id"]) == ids,
             "the batch handler persisted #{length(persisted)} of #{length(ids)} receipts — " <>
               "every id in the batch must be written, not just the first"
    end

    test "ONE frame covers N messages, and its key-sets are the pinned wire contract" do
      {:ok, _, socket} = join_channel()
      ids = ["m1", "m2", "m3"]

      ref = push(socket, "messages_delivered", %{"message_ids" => ids})
      assert_reply(ref, :ok)

      assert_broadcast("receipt_updated", frame)

      # OUTER shape identical to the single-message frame — nothing that already consumes
      # receipt_updated breaks at the envelope.
      assert frame |> Map.keys() |> Enum.sort() ==
               [:conversation_id, :event, :payload, :receipt_type, :status, :user_id]

      assert frame.receipt_type == "delivered"
      assert frame.event == "messages_delivered"
      assert frame.user_id == "reader"

      # INSIDE payload: the batch, plus the first id repeated for consumers written against the
      # single-message frame (degraded, never silent).
      assert frame.payload |> Map.keys() |> Enum.sort() == ["message_id", "message_ids"]
      assert frame.payload["message_ids"] == ids
      assert frame.payload["message_id"] == "m1"

      # Exactly ONE frame for the batch, not one per message.
      refute_broadcast("receipt_updated", _)
    end

    test "identity comes from the SOCKET — a payload cannot mark receipts as someone else" do
      {:ok, _, socket} = join_channel()

      ref =
        push(socket, "messages_read", %{
          "message_ids" => ["m1"],
          "user_id" => "someone_else",
          "conversation_id" => "another_conversation"
        })

      assert_reply(ref, :ok)

      [receipt] = MsgStub.persisted() |> Enum.filter(&(&1["status"] == "read"))
      assert receipt["user_id"] == "reader"
      assert receipt["conversation_id"] == "dm_1"
    end

    test "the batch honours the SAME read-receipt gate as the single event" do
      UserStub.set("reader", false)
      {:ok, _, socket} = join_channel()

      ref = push(socket, "messages_read", %{"message_ids" => ["m1", "m2"]})
      assert_reply(ref, :ok)

      # Persisted (the read is always durable) but NOT broadcast — a batch must not be a way around
      # the privacy setting.
      assert length(MsgStub.persisted()) == 2
      refute_broadcast("receipt_updated", _)
    end

    test "DELIVERED batches are never gated by the read-receipt setting" do
      UserStub.set("reader", false)
      {:ok, _, socket} = join_channel()

      ref = push(socket, "messages_delivered", %{"message_ids" => ["m1", "m2"]})
      assert_reply(ref, :ok)
      assert_broadcast("receipt_updated", %{receipt_type: "delivered"})
    end

    test "an over-sized batch is REFUSED, not silently truncated" do
      {:ok, _, socket} = join_channel()
      too_many = for i <- 1..101, do: "m#{i}"

      ref = push(socket, "messages_read", %{"message_ids" => too_many})
      assert_reply(ref, :error, %{code: "receipt.batch_too_large"})

      # Nothing persisted, nothing broadcast — a partial write would show the sender a tick state
      # that never fully arrives.
      assert MsgStub.persisted() == []
      refute_broadcast("receipt_updated", _)

      # The cap itself is accepted.
      ref = push(socket, "messages_read", %{"message_ids" => Enum.take(too_many, 100)})
      assert_reply(ref, :ok, %{accepted: 100})
    end

    test "an empty or malformed batch is refused without touching the store" do
      {:ok, _, socket} = join_channel()

      for bad <- [
            %{},
            %{"message_ids" => []},
            %{"message_ids" => "m1"},
            %{"message_ids" => [nil, ""]}
          ] do
        ref = push(socket, "messages_read", bad)
        assert_reply(ref, :error, %{code: "receipt.invalid_request"})
      end

      assert MsgStub.persisted() == []
    end

    test "duplicate ids in one batch are collapsed — a receipt is written once" do
      {:ok, _, socket} = join_channel()

      ref = push(socket, "messages_read", %{"message_ids" => ["m1", "m1", "m2", "m1"]})
      assert_reply(ref, :ok, %{accepted: 2})

      assert MsgStub.persisted() |> Enum.map(& &1["message_id"]) == ["m1", "m2"]
    end

    test "a batch is charged to the SAME ephemeral limiter as the single event — over it, dropped" do
      # RT_EPHEMERAL_LIMIT is read at the call site; 1/min means the second push is over budget.
      # Docker-free: the in-memory limiter adapter, reset so nothing bleeds in from another test.
      prev_limit = System.get_env("RT_EPHEMERAL_LIMIT")
      prev_adapter = Application.get_env(:shared_infra, :rate_limiter_adapter)

      Application.put_env(
        :shared_infra,
        :rate_limiter_adapter,
        SharedInfra.RateLimiter.InMemoryAdapter
      )

      SharedInfra.RateLimiter.InMemoryAdapter.reset()
      System.put_env("RT_EPHEMERAL_LIMIT", "1")

      on_exit(fn ->
        if prev_limit, do: System.put_env("RT_EPHEMERAL_LIMIT", prev_limit)

        if prev_adapter,
          do: Application.put_env(:shared_infra, :rate_limiter_adapter, prev_adapter)
      end)

      {:ok, _, socket} = join_channel()

      ref = push(socket, "messages_delivered", %{"message_ids" => ["m1"]})
      assert_reply(ref, :ok, %{accepted: 1})

      # Over the limit: an ephemeral is DROPPED SILENTLY (no reply), and nothing reaches the store.
      ref = push(socket, "messages_delivered", %{"message_ids" => ["m2", "m3"]})
      refute_reply(ref, :ok)
      refute_reply(ref, :error)

      assert MsgStub.persisted() |> Enum.map(& &1["message_id"]) == ["m1"],
             "the batch handler bypassed the ephemeral limiter — a new surface must not be a " <>
               "weaker door than message_delivered"
    end

    test "the single-message events still work, unchanged — Android and the SDK depend on them" do
      {:ok, _, socket} = join_channel()

      ref = push(socket, "message_read", %{"message_id" => "solo"})
      assert_reply(ref, :ok)
      assert_broadcast("receipt_updated", frame)
      assert frame.payload == %{"message_id" => "solo"}
      assert frame.receipt_type == "read"
    end
  end
end
