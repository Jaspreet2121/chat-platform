defmodule ConversationService.InboxCountersStoreRecountTest do
  @moduledoc """
  Under any non-Postgres message store, `InboxCounters.recount/2` asks the message service to
  recount from the STORE and never runs the Postgres `messages` lateral. That lateral, run against
  the truncated post-cutover table, sets every counter to 0 — the known bug — which is why it was
  interlocked off, leaving rejoins, window changes and read-repairs doing nothing at all.
  """
  use ExUnit.Case, async: false

  alias ConversationService.InboxCounters

  defmodule StoreStub do
    @moduledoc false
    def recount_unread(attrs) do
      send(:store_recount_test, {:recount_unread, attrs})
      {:ok, %{unread_count: 3, oldest_unread_at: "2026-09-25T00:00:00Z"}}
    end
  end

  defmodule DownStub do
    @moduledoc false
    def recount_unread(attrs) do
      send(:store_recount_test, {:recount_unread, attrs})
      {:error, :message_unavailable}
    end
  end

  setup do
    Process.register(self(), :store_recount_test)
    previous_backend = Application.get_env(:shared_infra, :message_store_backend)
    previous_adapter = Application.get_env(:shared_infra, :message_client_adapter)

    on_exit(fn ->
      restore = fn key, value ->
        if value,
          do: Application.put_env(:shared_infra, key, value),
          else: Application.delete_env(:shared_infra, key)
      end

      restore.(:message_store_backend, previous_backend)
      restore.(:message_client_adapter, previous_adapter)
    end)

    :ok
  end

  test "under the scylla store the recount is the message service's, keyed by (conversation, user)" do
    Application.put_env(:shared_infra, :message_store_backend, "scylla")
    Application.put_env(:shared_infra, :message_client_adapter, StoreStub)

    assert InboxCounters.recount("conv-1", "user-1") == :ok
    assert_receive {:recount_unread, %{"conversation_id" => "conv-1", "user_id" => "user-1"}}
  end

  test "an UNKNOWN backend is not Postgres either — it goes to the store, never to the lateral" do
    Application.delete_env(:shared_infra, :message_store_backend)
    Application.put_env(:shared_infra, :message_client_adapter, StoreStub)

    assert InboxCounters.recount("conv-2", "user-2") == :ok
    assert_receive {:recount_unread, %{"conversation_id" => "conv-2"}}
  end

  test "the read-repair callback takes the same road" do
    Application.put_env(:shared_infra, :message_store_backend, "scylla")
    Application.put_env(:shared_infra, :message_client_adapter, StoreStub)

    assert InboxCounters.repair("conv-3", "user-3", 42) == :ok
    assert_receive {:recount_unread, %{"conversation_id" => "conv-3"}}
  end

  test "a store that cannot answer leaves the counter alone — no fallback to the frozen table" do
    Application.put_env(:shared_infra, :message_store_backend, "scylla")
    Application.put_env(:shared_infra, :message_client_adapter, DownStub)

    # No Repo is started in this test: if the lateral ran, this would crash rather than return.
    assert InboxCounters.recount("conv-4", "user-4") == :ok
    assert_receive {:recount_unread, _}
  end
end
