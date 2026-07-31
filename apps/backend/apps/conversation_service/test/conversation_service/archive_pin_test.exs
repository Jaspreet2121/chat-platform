defmodule ConversationService.ArchivePinTest do
  @moduledoc """
  Archive + pin — per-participant inbox prefs (`@tag :postgres_integration`; the logic is SQL). Covers the
  ordering rule (pinned-first, newest-activity within each group), archived EXCLUDED from the default list but
  present in the ?archived=true list, the server pin cap (3) + `:pin_limit`, per-user isolation, stays-archived
  on a new message (with unread still computed), and that the single-conversation (broadcast) query returns an
  archived row so the client's flags update live. Fixtures mirror InboxRowsTest.
  """
  use ConversationService.DataCase, async: false

  alias ConversationService.{Conversations, Participants}

  @app_id "00000000-0000-0000-0000-000000000001"

  setup do
    previous = Application.get_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:conversation_service, :conversation_persistence, true)

    on_exit(fn ->
      Application.put_env(:conversation_service, :conversation_persistence, previous)
    end)

    :ok
  end

  defp user!(name) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, email, password_hash, created_at, updated_at) VALUES ($1::text::uuid, $2, 'x', now(), now())",
      [id, "#{name}-#{id}@test.local"]
    )

    id
  end

  defp conversation!(created_by) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, type, title, created_by, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, 'direct', NULL, $2::text::uuid, 'active', now(), now())",
      [id, created_by]
    )

    id
  end

  defp participant!(conversation_id, user_id) do
    Repo.query!(
      "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
      [conversation_id, user_id]
    )
  end

  defp message!(conversation_id, sender, body, seconds_ago \\ 0) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO messages (message_id, conversation_id, sender_user_id, message_type, body, status, created_at, app_id) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, 'text', $4, 'active', $5, $6::text::uuid)",
      [
        id,
        conversation_id,
        sender,
        body,
        DateTime.add(DateTime.utc_now(), -seconds_ago, :second),
        @app_id
      ]
    )

    ConversationService.InboxCounters.reconcile_conversation(conversation_id)
    id
  end

  # A direct chat between `owner` (+ optional `other`) with one message from `sender`, `seconds_ago` old.
  defp chat!(owner, opts \\ []) do
    c = conversation!(owner)
    participant!(c, owner)
    if other = opts[:other], do: participant!(c, other)
    message!(c, opts[:sender] || owner, opts[:body] || "hi", opts[:seconds_ago] || 0)
    c
  end

  defp ids(rows), do: Enum.map(rows, & &1.conversation_id)

  defp list(user),
    do: elem(Conversations.list_conversations(%{"user_id" => user}), 1).conversations

  defp archived_list(user),
    do:
      elem(Conversations.list_conversations(%{"user_id" => user, "archived" => true}), 1).conversations

  defp archive!(c, user, v),
    do: Participants.set_archive(%{"conversation_id" => c, "user_id" => user, "archived" => v})

  defp pin!(c, user, v),
    do: Participants.set_pin(%{"conversation_id" => c, "user_id" => user, "pinned" => v})

  @tag :postgres_integration
  test "archive EXCLUDES from the default list, shows in the archived list; unarchive restores; default rows report archived:false" do
    a = user!("a")
    c1 = chat!(a)
    c2 = chat!(a)

    assert Enum.sort(ids(list(a))) == Enum.sort([c1, c2])
    assert archived_list(a) == []

    assert {:ok, %{archived: true}} = archive!(c1, a, true)
    assert ids(list(a)) == [c2]
    assert Enum.all?(list(a), &(&1.archived == false))
    assert [%{conversation_id: ^c1, archived: true}] = archived_list(a)

    assert {:ok, %{archived: false}} = archive!(c1, a, false)
    assert Enum.sort(ids(list(a))) == Enum.sort([c1, c2])
    assert archived_list(a) == []
  end

  @tag :postgres_integration
  test "ORDERING: pinned first (newest-activity within each group), then the rest by activity" do
    a = user!("a")
    c1 = chat!(a, seconds_ago: 300)
    c2 = chat!(a, seconds_ago: 200)
    c3 = chat!(a, seconds_ago: 100)

    # Default: pure activity DESC.
    assert ids(list(a)) == [c3, c2, c1]

    # Pin the OLDEST → it jumps to the top; the rest keep activity order.
    assert {:ok, %{pinned: true}} = pin!(c1, a, true)
    assert ids(list(a)) == [c1, c3, c2]
    assert hd(list(a)).pinned == true

    # Pin c2 too → within the pinned group, newest-activity first (c2 newer than c1), then the unpinned c3.
    assert {:ok, _} = pin!(c2, a, true)
    assert ids(list(a)) == [c2, c1, c3]
  end

  @tag :postgres_integration
  test "PIN CAP: 3 max; the 4th → :pin_limit; re-pinning an existing one is idempotent; unpin frees a slot" do
    a = user!("a")
    [c1, c2, c3, c4] = for _ <- 1..4, do: chat!(a)

    assert {:ok, _} = pin!(c1, a, true)
    assert {:ok, _} = pin!(c2, a, true)
    assert {:ok, _} = pin!(c3, a, true)
    assert {:error, :pin_limit} = pin!(c4, a, true)

    # Re-pinning one already pinned is fine (idempotent — the cap counts pins OTHER than this one).
    assert {:ok, _} = pin!(c1, a, true)

    # Unpin one, and the 4th now fits.
    assert {:ok, _} = pin!(c1, a, false)
    assert {:ok, _} = pin!(c4, a, true)
  end

  @tag :postgres_integration
  test "PER-USER ISOLATION: my archive/pin never touches another participant's list" do
    a = user!("a")
    b = user!("b")
    c = chat!(a, other: b, sender: a)

    archive!(c, a, true)
    pin!(c, a, true)

    # a: gone from the default list, present in archived.
    assert list(a) == []
    assert [%{conversation_id: ^c}] = archived_list(a)

    # b: completely unaffected — still in the default list, neither archived nor pinned.
    assert [%{conversation_id: ^c, archived: false, pinned: false}] = list(b)
  end

  @tag :postgres_integration
  test "a NEW message to an archived chat leaves it archived; unread is still computed (in the archived list)" do
    a = user!("a")
    b = user!("b")
    c = conversation!(a)
    participant!(c, a)
    participant!(c, b)

    archive!(c, a, true)
    # b sends a new message after a archived.
    message!(c, b, "hey")

    # Still archived + excluded from a's default list…
    assert list(a) == []
    # …but the archived-list row still carries the unread (a new message does NOT unarchive).
    assert [row] = archived_list(a)
    assert row.conversation_id == c
    assert row.archived == true
    assert row.unread_count == 1
  end

  @tag :postgres_integration
  test "the single-conversation (broadcast) query returns an ARCHIVED row with both flags" do
    a = user!("a")
    c = chat!(a)
    archive!(c, a, true)
    pin!(c, a, true)

    assert {:ok, %{rows: [row]}} =
             Conversations.inbox_rows(%{"conversation_id" => c, "user_ids" => [a]})

    assert row.archived == true
    assert row.pinned == true
  end
end
