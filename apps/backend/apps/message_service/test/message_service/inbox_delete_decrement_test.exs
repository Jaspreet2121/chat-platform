defmodule MessageService.InboxDeleteDecrementTest do
  @moduledoc """
  The delete-for-everyone unread decrement — the deferred half of e36e1ae — and THE INTERLEAVING
  TABLE from the design review as executable rows. Create precedes delete on the topic (same
  partition key); the read decrement is synchronous and floats. Every row must land the counter on
  the value the table promises, or this slice ships the silent-drift class the previous three days
  were spent killing.

  The store stub is the InboxFromTopicTest shape (resolution by (conversation_id, message_id)
  alone). Counters are asserted directly on `conversation_participants`.
  """
  use MessageService.DataCase, async: false

  alias MessageService.InboxProjection
  alias MessageService.Projections.InboxFromTopic

  @tenant "00000000-0000-0000-0000-000000000001"

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

    def tombstone(conversation_id, message_id) do
      Agent.update(__MODULE__, fn state ->
        case Map.get(state, {conversation_id, message_id}) do
          nil ->
            state

          m ->
            Map.put(state, {conversation_id, message_id}, %{m | deleted_at: DateTime.utc_now()})
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

  # --- fixtures ------------------------------------------------------------------------------------

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active')",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp conversation!(members) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid)",
      [id, @tenant, hd(members)]
    )

    for u <- members do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
        [id, u]
      )
    end

    id
  end

  defp message(conversation, sender) do
    m = %{
      conversation_id: conversation,
      message_id: Ecto.UUID.generate(),
      sender_user_id: sender,
      message_type: "text",
      body: "hello",
      status: "active",
      metadata: %{},
      created_at: DateTime.utc_now(),
      deleted_at: nil
    }

    StoreStub.put(m)
    m
  end

  defp created_env(m) do
    %{
      "event_id" => Ecto.UUID.generate(),
      "event_type" => "message.created.v1",
      "payload" => %{
        "conversation_id" => m.conversation_id,
        "message_id" => m.message_id,
        "sender_user_id" => m.sender_user_id
      }
    }
  end

  defp deleted_env(m) do
    %{created_env(m) | "event_type" => "message.deleted.v1"}
    |> put_in(["payload", "deleted_at"], DateTime.utc_now())
  end

  defp unread(conversation, user) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT unread_count FROM conversation_participants " <>
          "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
        [conversation, user]
      )

    n
  end

  defp read!(m, reader),
    do: InboxProjection.record_read_once(m.conversation_id, m.message_id, reader, m)

  # --- (a)(c) fan-out ------------------------------------------------------------------------------

  @tag :postgres_integration
  test "(a)(c) delete decrements every UNREAD recipient; not the sender, not readers" do
    [sender, reader, u1, u2] = users = for _ <- 1..4, do: user!()
    conversation = conversation!(users)
    m = message(conversation, sender)

    assert {:ok, :applied} = InboxFromTopic.apply_message_created(created_env(m))
    assert Enum.map([reader, u1, u2], &unread(conversation, &1)) == [1, 1, 1]

    assert :applied = read!(m, reader)
    assert unread(conversation, reader) == 0

    # The sender holds unread from elsewhere — if the delete ever touches them, this catches it
    # (their own row at 0 would hide the bug behind the floor).
    Repo.query!(
      "UPDATE conversation_participants SET unread_count = 1 " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conversation, sender]
    )

    StoreStub.tombstone(conversation, m.message_id)
    assert {:ok, :applied} = InboxFromTopic.apply_message_deleted(deleted_env(m))

    assert unread(conversation, u1) == 0
    assert unread(conversation, u2) == 0
    # The reader already settled this message; their counter must not go below its correct 0.
    assert unread(conversation, reader) == 0
    # The sender was never incremented for their own message — untouched.
    assert unread(conversation, sender) == 1
  end

  # --- (b) exactly-once ----------------------------------------------------------------------------

  @tag :postgres_integration
  test "(b) a REDELIVERED delete and a SECOND delete event both decrement nothing" do
    [sender, recipient] = users = [user!(), user!()]
    conversation = conversation!(users)

    # Two messages so the recipient sits at 1 after the first delete — a double-decrement would
    # show as 0 instead of hiding behind the floor.
    m1 = message(conversation, sender)
    m2 = message(conversation, sender)
    assert {:ok, :applied} = InboxFromTopic.apply_message_created(created_env(m1))
    assert {:ok, :applied} = InboxFromTopic.apply_message_created(created_env(m2))
    assert unread(conversation, recipient) == 2

    StoreStub.tombstone(conversation, m1.message_id)
    env = deleted_env(m1)
    assert {:ok, :applied} = InboxFromTopic.apply_message_deleted(env)
    assert unread(conversation, recipient) == 1

    # Redelivered (same event_id): the ledger refuses the whole apply.
    assert {:ok, :duplicate} = InboxFromTopic.apply_message_deleted(env)
    assert unread(conversation, recipient) == 1

    # A SECOND delete of the same message (new event_id — a double-delete API call mints one): the
    # ledger passes it, the per-recipient CLAIMS refuse it.
    assert {:ok, :applied} = InboxFromTopic.apply_message_deleted(deleted_env(m1))
    assert unread(conversation, recipient) == 1
  end

  # --- (d) the interleaving table ------------------------------------------------------------------

  @tag :postgres_integration
  test "(d1) R -> C -> D: read before create consumed; everything converges to 0" do
    [sender, reader] = users = [user!(), user!()]
    conversation = conversation!(users)
    m = message(conversation, sender)

    # The reader beats the consumer: claim + floored decrement at 0.
    assert :applied = read!(m, reader)
    assert unread(conversation, reader) == 0

    # The create's increment skips the marked reader (the guard's original case).
    assert {:ok, :applied} = InboxFromTopic.apply_message_created(created_env(m))
    assert unread(conversation, reader) == 0

    StoreStub.tombstone(conversation, m.message_id)
    assert {:ok, :applied} = InboxFromTopic.apply_message_deleted(deleted_env(m))
    assert unread(conversation, reader) == 0
  end

  @tag :postgres_integration
  test "(d3) C -> D -> R: a read arriving after the delete changes nothing" do
    [sender, reader] = users = [user!(), user!()]
    conversation = conversation!(users)
    m = message(conversation, sender)

    assert {:ok, :applied} = InboxFromTopic.apply_message_created(created_env(m))
    StoreStub.tombstone(conversation, m.message_id)
    assert {:ok, :applied} = InboxFromTopic.apply_message_deleted(deleted_env(m))
    assert unread(conversation, reader) == 0

    # The late read: record_read_once bails on the tombstone (and its claim would conflict anyway).
    {:ok, tombstoned} =
      StoreStub.get_message(%{"conversation_id" => conversation, "message_id" => m.message_id})

    assert :ok = read!(tombstoned, reader)
    assert unread(conversation, reader) == 0
  end

  @tag :postgres_integration
  test "(d4) tombstone -> C(skip) -> D: the settle-marks stop the drift — THE NEW PIECE" do
    [sender, recipient] = users = [user!(), user!()]
    conversation = conversation!(users)

    # The recipient holds one REAL unread from another message; the fast-deleted message must not
    # steal its count.
    other = message(conversation, sender)
    assert {:ok, :applied} = InboxFromTopic.apply_message_created(created_env(other))
    assert unread(conversation, recipient) == 1

    # Fast delete: tombstoned BEFORE its create is consumed.
    m = message(conversation, sender)
    StoreStub.tombstone(conversation, m.message_id)

    assert {:ok, :skipped_absent} = InboxFromTopic.apply_message_created(created_env(m))
    # No increment happened...
    assert unread(conversation, recipient) == 1

    # ...so the delete must decrement NOBODY. Without the create-skip settle-marks it would take
    # the other message's count.
    assert {:ok, :applied} = InboxFromTopic.apply_message_deleted(deleted_env(m))
    assert unread(conversation, recipient) == 1
  end

  @tag :postgres_integration
  test "(d5) R -> tombstone -> C(skip) -> D: the fast reader and the settle compose" do
    [sender, reader, bystander] = users = [user!(), user!(), user!()]
    conversation = conversation!(users)
    m = message(conversation, sender)

    assert :applied = read!(m, reader)
    StoreStub.tombstone(conversation, m.message_id)

    # The skip settles the bystander; the reader's own mark already exists (conflict, fine).
    assert {:ok, :skipped_absent} = InboxFromTopic.apply_message_created(created_env(m))
    assert {:ok, :applied} = InboxFromTopic.apply_message_deleted(deleted_env(m))

    assert unread(conversation, reader) == 0
    assert unread(conversation, bystander) == 0
  end

  @tag :postgres_integration
  test "(d8/e) the ACCEPTED RESIDUAL: create event lost entirely -> floor absorbs at 0" do
    [sender, recipient] = users = [user!(), user!()]
    conversation = conversation!(users)
    m = message(conversation, sender)
    StoreStub.tombstone(conversation, m.message_id)

    # No create event was ever consumed (fire-and-forget publish failure). The delete claims and
    # decrements a never-counted message: at 0 the GREATEST floor holds. This drift (documented as
    # interleaving row 8) is ACCEPTED — this test pins both the floor and the residual, so neither
    # is a surprise.
    assert unread(conversation, recipient) == 0
    assert {:ok, :applied} = InboxFromTopic.apply_message_deleted(deleted_env(m))
    assert unread(conversation, recipient) == 0
  end
end
