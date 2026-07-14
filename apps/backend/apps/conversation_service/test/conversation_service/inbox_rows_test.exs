defmodule ConversationService.InboxRowsTest do
  @moduledoc """
  `inbox_rows/1` — the per-user rows behind the `conversation_updated` broadcast.

  These are the tests that matter for this feature: they prove the row is genuinely PER-USER (two people in
  the same conversation, at the same instant, correctly see different unread counts AND different previews),
  which is the whole reason the broadcaster fetches a row per participant instead of one shared row.

  DB-backed (`@tag :postgres_integration`) because the logic being tested IS SQL — a stubbed adapter would
  only test the stub. Requires a prepared local Postgres.
  """
  use ConversationService.DataCase, async: false

  alias ConversationService.Conversations

  # The default tenant the init schema seeds as app_id's fallback everywhere.
  @app_id "00000000-0000-0000-0000-000000000001"

  setup do
    previous = Application.get_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:conversation_service, :conversation_persistence, true)
    on_exit(fn -> Application.put_env(:conversation_service, :conversation_persistence, previous) end)
    :ok
  end

  # --- fixtures (raw SQL: these tables are shared across services and have no local schemas here) ---

  defp user!(name) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, email, password_hash, created_at, updated_at) VALUES ($1::text::uuid, $2, 'x', now(), now())",
      [id, "#{name}-#{id}@test.local"]
    )

    id
  end

  defp conversation!(type, title, created_by) do
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO conversations (id, type, title, created_by, status, created_at, updated_at)
      VALUES ($1::text::uuid, $2, $3, $4::text::uuid, 'active', now(), now())
      """,
      [id, type, title, created_by]
    )

    id
  end

  defp participant!(conversation_id, user_id, opts \\ []) do
    Repo.query!(
      """
      INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at, cleared_before)
      VALUES ($1::text::uuid, $2::text::uuid, $3, now(), $4)
      """,
      [conversation_id, user_id, Keyword.get(opts, :role, "member"), Keyword.get(opts, :cleared_before)]
    )
  end

  # NB: `messages` has no updated_at, and app_id is NOT NULL with no default.
  defp message!(conversation_id, sender_user_id, body, opts \\ []) do
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO messages (message_id, conversation_id, sender_user_id, message_type, body, status, created_at, app_id)
      VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, $4, $5, 'active', $6, $7::text::uuid)
      """,
      [
        id,
        conversation_id,
        sender_user_id,
        Keyword.get(opts, :message_type, "text"),
        body,
        Keyword.get(opts, :at, DateTime.utc_now()),
        @app_id
      ]
    )

    id
  end

  defp read!(conversation_id, message_id, user_id) do
    Repo.query!(
      """
      INSERT INTO message_receipts (conversation_id, message_id, user_id, status, read_at, updated_at)
      VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, 'read', now(), now())
      """,
      [conversation_id, message_id, user_id]
    )
  end

  defp group_profile!(conversation_id, name) do
    Repo.query!(
      """
      INSERT INTO group_profiles (conversation_id, name, created_at, updated_at)
      VALUES ($1::text::uuid, $2, now(), now())
      """,
      [conversation_id, name]
    )
  end

  defp row_for(rows, user_id), do: Enum.find(rows, &(&1.user_id == user_id))

  # --- the tests ---

  @tag :postgres_integration
  test "THE POINT: in a 3-person conversation each participant gets THEIR OWN unread — and they differ" do
    a = user!("alice")
    b = user!("bob")
    c = user!("carol")
    conv = conversation!("group", "Launch", a)
    participant!(conv, a, role: "owner")
    participant!(conv, c)

    # Bob CLEARED his history just now — messages before this instant are invisible to him, and must not
    # count toward his unread NOR appear as his preview. Carol has no such window.
    old = message!(conv, a, "before bob cleared", at: DateTime.add(DateTime.utc_now(), -60, :second))
    participant!(conv, b, cleared_before: DateTime.add(DateTime.utc_now(), -30, :second))

    _new = message!(conv, a, "after bob cleared")

    assert {:ok, %{rows: rows}} =
             Conversations.inbox_rows(%{"conversation_id" => conv, "user_ids" => [a, b, c]})

    assert length(rows) == 3

    # The SENDER never accrues unread from her own messages (m.sender_user_id <> cp.user_id).
    assert row_for(rows, a).unread_count == 0

    # Bob sees ONLY the message after his clear → 1 unread. Carol sees both → 2. Same conversation, same
    # instant, DIFFERENT counts: this is precisely why one shared row + per-user counts would be wrong.
    assert row_for(rows, b).unread_count == 1
    assert row_for(rows, c).unread_count == 2

    # …and the PREVIEW is per-user too — Bob must never be shown a preview of a message he cleared.
    assert row_for(rows, b).last_message_preview == "after bob cleared"
    assert row_for(rows, c).last_message_preview == "after bob cleared"

    # Carol reads the older message → her count drops; Bob's is untouched.
    read!(conv, old, c)

    assert {:ok, %{rows: rows}} =
             Conversations.inbox_rows(%{"conversation_id" => conv, "user_ids" => [a, b, c]})

    assert row_for(rows, c).unread_count == 1
    assert row_for(rows, b).unread_count == 1
  end

  @tag :postgres_integration
  test "a read receipt drops the reader's count to zero (the receipt trigger's payload)" do
    a = user!("alice")
    b = user!("bob")
    conv = conversation!("direct", nil, a)
    participant!(conv, a)
    participant!(conv, b)

    m1 = message!(conv, a, "one")
    m2 = message!(conv, a, "two")

    assert {:ok, %{rows: rows}} =
             Conversations.inbox_rows(%{"conversation_id" => conv, "user_ids" => [b]})

    assert row_for(rows, b).unread_count == 2

    read!(conv, m1, b)
    read!(conv, m2, b)

    assert {:ok, %{rows: rows}} =
             Conversations.inbox_rows(%{"conversation_id" => conv, "user_ids" => [b]})

    assert row_for(rows, b).unread_count == 0
  end

  @tag :postgres_integration
  test "title resolves to group_profiles.name (the rename source of truth), falling back to c.title" do
    a = user!("alice")
    conv = conversation!("group", "Original Title", a)
    participant!(conv, a, role: "owner")

    # No group_profiles row yet → the fallback (c.title).
    assert {:ok, %{rows: [row]}} =
             Conversations.inbox_rows(%{"conversation_id" => conv, "user_ids" => [a]})

    assert row.title == "Original Title"

    # A rename writes group_profiles.name — which the inbox must now prefer. Before this change the list read
    # c.title and a renamed group kept its OLD name in the inbox forever.
    group_profile!(conv, "Renamed Group")

    assert {:ok, %{rows: [row]}} =
             Conversations.inbox_rows(%{"conversation_id" => conv, "user_ids" => [a]})

    assert row.title == "Renamed Group"
  end

  @tag :postgres_integration
  test "a DIRECT chat has no group_profiles row at all → title falls through to c.title" do
    a = user!("alice")
    b = user!("bob")
    conv = conversation!("direct", nil, a)
    participant!(conv, a)
    participant!(conv, b)

    assert {:ok, %{rows: rows}} =
             Conversations.inbox_rows(%{"conversation_id" => conv, "user_ids" => [a, b]})

    assert Enum.all?(rows, &is_nil(&1.title))
    assert length(rows) == 2
  end

  @tag :postgres_integration
  test "a REMOVED participant has no row (left_at set) — which is why they get a `removed` frame instead" do
    a = user!("alice")
    b = user!("bob")
    conv = conversation!("group", "Team", a)
    participant!(conv, a, role: "owner")
    participant!(conv, b)

    Repo.query!(
      "UPDATE conversation_participants SET left_at = now() WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conv, b]
    )

    assert {:ok, %{rows: rows}} =
             Conversations.inbox_rows(%{"conversation_id" => conv, "user_ids" => [a, b]})

    assert [%{user_id: ^a}] = rows
    refute row_for(rows, b)
  end

  @tag :postgres_integration
  test "the list path and inbox_rows agree — the SAME SQL, so an unread count can never drift between them" do
    a = user!("alice")
    b = user!("bob")
    conv = conversation!("group", "Shared", a)
    participant!(conv, a, role: "owner")
    participant!(conv, b)
    message!(conv, a, "hello")
    message!(conv, a, "again")

    {:ok, %{conversations: list_rows}} = Conversations.list_conversations(%{"user_id" => b})
    {:ok, %{rows: [broadcast_row]}} = Conversations.inbox_rows(%{"conversation_id" => conv, "user_ids" => [b]})

    list_row = Enum.find(list_rows, &(&1.conversation_id == conv))

    # Everything the inbox shows must be identical whether it came from a refetch or a live broadcast.
    assert list_row.unread_count == broadcast_row.unread_count
    assert list_row.last_message_preview == broadcast_row.last_message_preview
    assert list_row.title == broadcast_row.title
    assert list_row.updated_at == broadcast_row.updated_at
    # The list row carries no user_id (it's implicit); the broadcast row needs it as the routing key.
    refute Map.has_key?(list_row, :user_id)
  end

  @tag :postgres_integration
  test "invalid input is rejected, not crashed" do
    assert {:error, :conversation_invalid} =
             Conversations.inbox_rows(%{"conversation_id" => Ecto.UUID.generate(), "user_ids" => []})

    assert {:error, :conversation_invalid} =
             Conversations.inbox_rows(%{"conversation_id" => "not-a-uuid", "user_ids" => [Ecto.UUID.generate()]})

    assert {:error, :conversation_invalid} =
             Conversations.inbox_rows(%{"conversation_id" => Ecto.UUID.generate(), "user_ids" => ["nope"]})
  end
end
