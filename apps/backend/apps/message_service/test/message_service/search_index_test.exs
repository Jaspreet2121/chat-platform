defmodule MessageService.SearchIndexTest do
  @moduledoc """
  The search-only copy of message text (DECISION_LOG [2026-08-08]): the projection that maintains
  `message_search`, the consumer classification that protects it, and the backfill's no-overwrite
  contract. The store here is the InboxFromTopicTest `StoreStub` (see its comment for why
  InMemoryAdapter is unusable); the projection reads it through the same `MessageStore.get_message`
  boundary production uses. The END-TO-END proof against live Scylla (real adapter, hydration
  drift-drop) is in `ScyllaStoreIntegrationTest`.
  """
  use MessageService.DataCase, async: false

  import ExUnit.CaptureLog

  alias MessageService.Events.SearchIndexConsumer
  alias MessageService.Projections.SearchIndex

  @tenant_zero "00000000-0000-0000-0000-000000000001"

  # The InboxFromTopicTest store stub, for that test's recorded reason: the projection resolves a
  # message from (conversation_id, message_id) ALONE — ScyllaAdapter derives the bucket from the
  # timeuuid — and InMemoryAdapter demands an explicit "bucket_date" the event payload never
  # carries. Using it would test a contract production never meets.
  defmodule StoreStub do
    @moduledoc false
    use Agent

    def start do
      case Agent.start_link(fn -> %{} end, name: __MODULE__) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end

    def reset, do: Agent.update(__MODULE__, fn _ -> %{} end)

    def put(message),
      do:
        Agent.update(
          __MODULE__,
          &Map.put(&1, {message.conversation_id, message.message_id}, message)
        )

    def get_message(attrs) do
      key = {attrs["conversation_id"], attrs["message_id"]}

      case Agent.get(__MODULE__, &Map.get(&1, key)) do
        nil -> {:error, :message_not_found}
        message -> {:ok, message}
      end
    end

    def list_messages(attrs) do
      conversation_id = attrs["conversation_id"]

      messages =
        Agent.get(__MODULE__, &Map.values(&1))
        |> Enum.filter(&(&1.conversation_id == conversation_id))
        |> Enum.sort_by(& &1.created_at, {:desc, DateTime})

      {:ok, %{messages: messages, next_cursor: nil}}
    end
  end

  setup do
    prev_store = Application.get_env(:message_service, :message_store_adapter)
    Application.put_env(:message_service, :message_store_adapter, StoreStub)
    StoreStub.start()
    StoreStub.reset()

    on_exit(fn ->
      if prev_store,
        do: Application.put_env(:message_service, :message_store_adapter, prev_store),
        else: Application.delete_env(:message_service, :message_store_adapter)
    end)

    :ok
  end

  defp put_in_store!(conversation_id, message_id, opts \\ []) do
    StoreStub.put(%{
      conversation_id: conversation_id,
      message_id: message_id,
      sender_user_id: Keyword.get(opts, :sender, Ecto.UUID.generate()),
      message_type: "text",
      body: Keyword.get(opts, :body, "hello"),
      status: Keyword.get(opts, :status, "active"),
      metadata: %{},
      created_at: Keyword.get(opts, :created_at, DateTime.utc_now()),
      deleted_at: Keyword.get(opts, :deleted_at)
    })

    :ok
  end

  defp envelope(type, conversation_id, message_id) do
    %{
      "event_id" => Ecto.UUID.generate(),
      "event_type" => type,
      "payload" => %{"conversation_id" => conversation_id, "message_id" => message_id}
    }
  end

  defp seed_conversation!(conversation, creator) do
    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active')",
      [creator, @tenant_zero, "+1555#{System.unique_integer([:positive])}"]
    )

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid)",
      [conversation, @tenant_zero, creator]
    )
  end

  defp indexed_text(message_id) do
    case Repo.query!("SELECT search_text FROM message_search WHERE message_id = $1::text::uuid", [
           message_id
         ]) do
      %{rows: [[text]]} -> text
      %{rows: []} -> :no_row
    end
  end

  describe "apply_event" do
    @tag :postgres_integration
    test "created indexes the READ-BACK body; duplicate delivery indexes once" do
      conversation = Ecto.UUID.generate()
      message = Ecto.UUID.generate()
      put_in_store!(conversation, message, body: "find me by this text")

      env = envelope("message.created.v1", conversation, message)

      assert {:ok, :applied} = SearchIndex.apply_message_created(env)
      assert indexed_text(message) == "find me by this text"

      # SAME event_id again: the ledger refuses it. (An overwrite of identical data would be
      # harmless, but the ledger is the contract every projection here shares.)
      assert {:ok, :duplicate} = SearchIndex.apply_message_created(env)
    end

    @tag :postgres_integration
    test "a message DELETED before its create is consumed indexes NOTHING" do
      conversation = Ecto.UUID.generate()
      message = Ecto.UUID.generate()

      put_in_store!(conversation, message,
        body: "deleted secret",
        deleted_at: DateTime.utc_now()
      )

      env = envelope("message.created.v1", conversation, message)

      # :skipped_absent, ledgered — deletion-propagation's front door: tombstoned text never
      # enters the copy at all.
      assert {:ok, :skipped_absent} = SearchIndex.apply_message_created(env)
      assert indexed_text(message) == :no_row
    end

    @tag :postgres_integration
    test "deleted removes the row" do
      conversation = Ecto.UUID.generate()
      message = Ecto.UUID.generate()
      put_in_store!(conversation, message, body: "short-lived")

      env = envelope("message.created.v1", conversation, message)
      assert {:ok, :applied} = SearchIndex.apply_message_created(env)
      refute indexed_text(message) == :no_row

      assert {:ok, :applied} =
               SearchIndex.apply_message_deleted(
                 envelope("message.deleted.v1", conversation, message)
               )

      assert indexed_text(message) == :no_row
    end

    @tag :postgres_integration
    test "unknown event types are ignored, not errors" do
      assert {:ok, :ignored} = SearchIndex.apply_event(%{"event_type" => "something.else.v9"})
    end
  end

  describe "refresh_text/3 (the edit path)" do
    @tag :postgres_integration
    test "overwrites the indexed text so edited-out content stops matching" do
      conversation = Ecto.UUID.generate()
      message = Ecto.UUID.generate()
      put_in_store!(conversation, message, body: "call me on 0555 123456")

      env = envelope("message.created.v1", conversation, message)
      assert {:ok, :applied} = SearchIndex.apply_message_created(env)

      assert :ok = SearchIndex.refresh_text(message, "call me on signal", nil)
      assert indexed_text(message) == "call me on signal"
    end

    @tag :postgres_integration
    test "an edit arriving before the create is a harmless no-op" do
      assert :ok = SearchIndex.refresh_text(Ecto.UUID.generate(), "early edit", nil)
    end
  end

  describe "backfill" do
    @tag :postgres_integration
    test "NEVER overwrites an existing row — the consumer's fresher write wins" do
      conversation = Ecto.UUID.generate()
      message = Ecto.UUID.generate()
      sender = Ecto.UUID.generate()

      seed_conversation!(conversation, sender)

      # The store holds the OLD text (as a backfill's read might, seconds behind an edit) …
      put_in_store!(conversation, message, sender: sender, body: "old text the backfill read")

      # … while the index already holds the FRESHER consumer/edit-written text.
      {:ok, _} =
        Repo.transaction(fn ->
          SearchIndex.upsert(%{
            message_id: message,
            conversation_id: conversation,
            sender_user_id: sender,
            created_at: DateTime.utc_now(),
            body: "fresher text from the consumer"
          })
        end)

      counts = MessageService.SearchBackfill.backfill_conversation(conversation)

      # ON CONFLICT DO NOTHING: the fresher row survives, and the task reports the skip.
      assert indexed_text(message) == "fresher text from the consumer"
      assert counts.skipped_existing >= 1
      assert counts.indexed == 0
    end

    @tag :postgres_integration
    test "indexes live rows, skips tombstones, and is idempotent on re-run" do
      conversation = Ecto.UUID.generate()
      sender = Ecto.UUID.generate()
      live = Ecto.UUID.generate()
      dead = Ecto.UUID.generate()

      seed_conversation!(conversation, sender)

      put_in_store!(conversation, live, sender: sender, body: "backfilled body")
      put_in_store!(conversation, dead, sender: sender, deleted_at: DateTime.utc_now())

      first = MessageService.SearchBackfill.backfill_conversation(conversation)
      assert first.indexed == 1
      assert first.deleted == 1
      assert indexed_text(live) == "backfilled body"
      assert indexed_text(dead) == :no_row

      second = MessageService.SearchBackfill.backfill_conversation(conversation)
      assert second.indexed == 0
      assert second.skipped_existing == 1
    end
  end

  describe "commit_decision" do
    test "a MISSING message_search table RETRIES — code-before-migration must stall, not drop" do
      # The inbox consumer classifies every Postgrex.Error as poison; applied here, a deploy that
      # beats the 094 migration would permanently drop every message's searchability. undefined_table
      # is an operational precondition, not a property of the event.
      error = {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}}

      capture_log(fn ->
        assert :retry = SearchIndexConsumer.commit_decision(error, 0)
      end)
    end

    test "other deterministic errors are still poison (commit), transient still retries" do
      capture_log(fn ->
        # A constraint violation is in the event's data: retrying forever wedges the partition.
        assert :commit =
                 SearchIndexConsumer.commit_decision(
                   {:error, %Postgrex.Error{postgres: %{code: :not_null_violation}}},
                   0
                 )

        assert :retry =
                 SearchIndexConsumer.commit_decision(
                   {:error, %DBConnection.ConnectionError{message: "pool timeout"}},
                   0
                 )

        assert :commit = SearchIndexConsumer.commit_decision({:ok, :applied}, 0)
        assert :commit = SearchIndexConsumer.commit_decision({:ok, :duplicate}, 0)
        assert :commit = SearchIndexConsumer.commit_decision({:error, :invalid_event}, 0)
      end)
    end
  end
end
