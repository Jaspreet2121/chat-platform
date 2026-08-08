defmodule MessageService.Projections.InboxFromTopicTest do
  @moduledoc """
  THE INBOX PROJECTION FED FROM THE TOPIC (086, post-cutover).

  Under `MESSAGE_STORE_ADAPTER=scylla` the same-transaction write in `MessageStore.PostgresAdapter`
  never runs, so preview and unread freeze — measured, silently. This projection replaces it from
  `message.events.v1`.

  The load-bearing assertions here are the two that are about correctness rather than plumbing:

    * `message.deleted` must remove the deleted body from the preview. A preview fed by creates alone
      keeps showing deleted TEXT in the chat list forever — deleted content on screen, the class this
      codebase has already fixed twice.
    * the ledger must make double delivery harmless, because this consumer is the SINGLE idempotent
      writer of the unread increment and the recount design depends on that.
  """
  use MessageService.DataCase, async: false

  alias MessageService.Projections.InboxFromTopic

  # A stub store modelling the SCYLLA contract: `get_message/1` resolves from
  # (conversation_id, message_id) ALONE, because ScyllaAdapter derives the partition's bucket from
  # the timeuuid (ScyllaCodec.bucket_candidates/1) and PostgresAdapter looks up by primary key.
  # InMemoryAdapter is NOT usable here — it requires an explicit "bucket_date" its siblings derive,
  # and the event payload carries no bucket. Using it would have tested a contract the projection
  # will never meet in production.
  defmodule StoreStub do
    @moduledoc false
    use Agent

    def start, do: Agent.start_link(fn -> %{} end, name: __MODULE__)
    def reset, do: Agent.update(__MODULE__, fn _ -> %{} end)

    def put(message),
      do:
        Agent.update(
          __MODULE__,
          &Map.put(&1, {message.conversation_id, message.message_id}, message)
        )

    def tombstone(conversation_id, message_id) do
      Agent.update(__MODULE__, fn state ->
        case Map.get(state, {conversation_id, message_id}) do
          nil -> state
          m -> Map.put(state, {conversation_id, message_id}, %{m | status: "deleted"})
        end
      end)
    end

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

  @tenant "00000000-0000-0000-0000-000000000001"

  setup do
    prev_adapter = Application.get_env(:message_service, :message_store_adapter)

    # The projection self-gates when PostgresAdapter is selected; these tests exercise the
    # post-cutover world, so pin the Scylla-shaped stub.
    case StoreStub.start() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    StoreStub.reset()
    Application.put_env(:message_service, :message_store_adapter, StoreStub)

    on_exit(fn ->
      if prev_adapter,
        do: Application.put_env(:message_service, :message_store_adapter, prev_adapter),
        else: Application.delete_env(:message_service, :message_store_adapter)
    end)

    :ok
  end

  defp uuid, do: Ecto.UUID.generate()

  defp user! do
    id = uuid()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active', now(), now())",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp conversation!(participants) do
    id = uuid()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid, 'active', now(), now())",
      [id, @tenant, hd(participants)]
    )

    for u <- participants do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
        [id, u]
      )
    end

    id
  end

  # Put a message in the STORE (what the projection reads back), without touching Postgres inbox
  # columns — exactly the post-cutover shape.
  defp store!(conversation_id, sender, body, opts \\ []) do
    message_id = Keyword.get(opts, :message_id, uuid())

    StoreStub.put(%{
      conversation_id: conversation_id,
      message_id: message_id,
      sender_user_id: sender,
      message_type: "text",
      body: body,
      status: Keyword.get(opts, :status, "active"),
      created_at: Keyword.get(opts, :created_at, DateTime.utc_now()),
      metadata: %{}
    })

    message_id
  end

  defp created_event(conversation_id, message_id, sender) do
    %{
      "event_id" => uuid(),
      "event_type" => "message.created.v1",
      "payload" => %{
        "conversation_id" => conversation_id,
        "message_id" => message_id,
        "sender_user_id" => sender
      }
    }
  end

  defp deleted_event(conversation_id, message_id, sender) do
    %{
      "event_id" => uuid(),
      "event_type" => "message.deleted.v1",
      "payload" => %{
        "conversation_id" => conversation_id,
        "message_id" => message_id,
        "sender_user_id" => sender
      }
    }
  end

  defp preview(conversation_id) do
    %{rows: [[id, body]]} =
      Repo.query!(
        "SELECT last_message_id::text, last_message_body FROM conversations WHERE id = $1::text::uuid",
        [conversation_id]
      )

    {id, body}
  end

  defp unread(conversation_id, user_id) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT unread_count FROM conversation_participants " <>
          "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
        [conversation_id, user_id]
      )

    n
  end

  @tag :postgres_integration
  test "(a) DOUBLE DELIVERY of the same message.created applies exactly once" do
    sender = user!()
    peer = user!()
    conversation = conversation!([sender, peer])
    message_id = store!(conversation, sender, "hello")
    event = created_event(conversation, message_id, sender)

    assert {:ok, :applied} = InboxFromTopic.apply_message_created(event)
    assert unread(conversation, peer) == 1

    # Redelivery of the SAME event_id — the ledger must make it a no-op. Without it the counter
    # double-increments and this consumer stops being the single idempotent writer the recount
    # design assumes.
    assert {:ok, :duplicate} = InboxFromTopic.apply_message_created(event)
    assert unread(conversation, peer) == 1
  end

  @tag :postgres_integration
  test "(b) the SENDER's own unread does not increment" do
    sender = user!()
    peer = user!()
    conversation = conversation!([sender, peer])
    message_id = store!(conversation, sender, "hello")

    assert {:ok, :applied} =
             InboxFromTopic.apply_message_created(created_event(conversation, message_id, sender))

    assert unread(conversation, peer) == 1
    assert unread(conversation, sender) == 0
  end

  @tag :postgres_integration
  test "(c) THE PRIVACY ASSERTION: message.deleted removes the deleted body from the preview" do
    sender = user!()
    peer = user!()
    conversation = conversation!([sender, peer])

    older =
      store!(conversation, sender, "older", created_at: DateTime.add(DateTime.utc_now(), -60))

    newest = store!(conversation, sender, "SECRET to be deleted")

    InboxFromTopic.apply_message_created(created_event(conversation, older, sender))
    InboxFromTopic.apply_message_created(created_event(conversation, newest, sender))

    assert {^newest, "SECRET to be deleted"} = preview(conversation)

    # Delete-for-everyone must reach the chat list. Mark it deleted in the store, then deliver the
    # event the way the topic would.
    StoreStub.tombstone(conversation, newest)

    assert {:ok, :applied} =
             InboxFromTopic.apply_message_deleted(deleted_event(conversation, newest, sender))

    {preview_id, preview_body} = preview(conversation)

    refute preview_body == "SECRET to be deleted",
           "the deleted message's text must not remain in the chat list"

    assert preview_id == older, "the preview must promote the next-newest live message"
    assert preview_body == "older"
  end

  @tag :postgres_integration
  test "(d) a read-back that returns NOT-FOUND is a defined outcome, not an error or a retry" do
    sender = user!()
    peer = user!()
    conversation = conversation!([sender, peer])

    # An event for a message that is not in the store: created then deleted before the consumer got
    # to it. Defined behaviour — ledger it, change nothing. NOT {:error, _}, which the consumer would
    # treat as retry-forever.
    orphan = uuid()
    event = created_event(conversation, orphan, sender)

    assert {:ok, :skipped_absent} = InboxFromTopic.apply_message_created(event)

    assert unread(conversation, peer) == 0, "a message nobody can open must not count as unread"
    assert {nil, nil} = preview(conversation)

    # And it IS ledgered, so redelivering the same event is a cheap duplicate rather than another
    # store read — "absent" is a decision, not a deferral.
    assert {:ok, :duplicate} = InboxFromTopic.apply_message_created(event)
  end

  @tag :postgres_integration
  test "(e) a CRASH between the ledger insert and the projection write rolls BOTH back" do
    sender = user!()
    peer = user!()
    conversation = conversation!([sender, peer])
    message_id = store!(conversation, sender, "hello")
    event = created_event(conversation, message_id, sender)

    # Force the projection write to RAISE inside the transaction, after the ledger insert has already
    # happened. Deleting the target rows does NOT work — an UPDATE matching zero rows succeeds — so
    # the store returns a created_at Postgrex cannot encode, which raises in record_message's query.
    # If the ledger insert and the projection write were not in ONE transaction, the event would be
    # recorded as applied while the counter never moved, and redelivery would skip it forever.
    StoreStub.put(%{
      conversation_id: conversation,
      message_id: message_id,
      sender_user_id: sender,
      message_type: "text",
      body: "hello",
      status: "active",
      created_at: "not-a-timestamp",
      metadata: %{}
    })

    assert {:error, _} = InboxFromTopic.apply_message_created(event)

    # The counter must be untouched too.
    assert unread(conversation, peer) == 0

    # The ledger must NOT contain the event — it rolled back with the failed write.
    %{rows: [[ledgered]]} =
      Repo.query!(
        "SELECT count(*) FROM processed_events WHERE consumer = $1 AND event_id = $2::text::uuid",
        [InboxFromTopic.consumer_name(), event["event_id"]]
      )

    assert ledgered == 0, "a rolled-back apply must leave no ledger row, or redelivery is lost"
  end

  @tag :postgres_integration
  test "THE INTERLOCK: with PostgresAdapter selected the projection writes NOTHING" do
    # InboxProjection already maintains these columns inside the message transaction under that
    # adapter. Two writers would double every unread increment, so this must be inert — enabling the
    # consumer flag before the cutover has to be safe.
    Application.put_env(
      :message_service,
      :message_store_adapter,
      MessageService.MessageStore.PostgresAdapter
    )

    sender = user!()
    peer = user!()
    conversation = conversation!([sender, peer])

    assert {:ok, :skipped_postgres_adapter} =
             InboxFromTopic.apply_message_created(created_event(conversation, uuid(), sender))

    assert unread(conversation, peer) == 0
  end

  @tag :postgres_integration
  test "an unknown event type is ignored, not an error" do
    assert {:ok, :ignored} =
             InboxFromTopic.apply_event(%{
               "event_id" => uuid(),
               "event_type" => "message.updated.v1",
               "payload" => %{}
             })
  end
end
