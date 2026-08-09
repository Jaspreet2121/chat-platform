defmodule ConversationService.AdminMessageCountTest do
  @moduledoc """
  Drop-blocker #2 (DECISION_LOG [2026-08-09]): the admin conversation endpoints' `message_count`
  now comes from `message_search` — the live store's copy — not the frozen Postgres `messages`
  table, whose counts were stuck at their pre-cutover values.

  The frozen-vs-live discrimination is the load-bearing test: a conversation with rows in BOTH
  tables must count only the indexed live ones, or the re-point silently didn't happen. The
  response shape is asserted KEY-EXACT before anything else — these endpoints feed the first-party
  admin console, and a shape change there breaks it silently (`?? 0` renders zero, not an error).
  """
  use ConversationService.DataCase, async: false

  alias ConversationService.Conversations

  @tenant "00000000-0000-0000-0000-000000000001"

  setup do
    previous = Application.get_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:conversation_service, :conversation_persistence, true)

    on_exit(fn ->
      Application.put_env(:conversation_service, :conversation_persistence, previous)
    end)

    :ok
  end

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

  # A FROZEN-era row: exists only in Postgres `messages`, as pre-cutover history does.
  defp frozen_message!(conversation, sender) do
    Repo.query!(
      "INSERT INTO messages (message_id, conversation_id, app_id, sender_user_id, message_type, " <>
        "body, created_at) VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, " <>
        "$4::text::uuid, 'text', 'frozen era', now() - interval '30 days')",
      [Ecto.UUID.generate(), conversation, @tenant, sender]
    )
  end

  # A LIVE message as the store sees it: an index row (the search consumer's write).
  defp indexed_message!(conversation, sender) do
    Repo.query!(
      "INSERT INTO message_search (message_id, conversation_id, sender_user_id, created_at, " <>
        "search_text) VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, now(), 'live')",
      [Ecto.UUID.generate(), conversation, sender]
    )
  end

  @tag :postgres_integration
  test "admin_list_conversations counts the LIVE store's copy, never the frozen table" do
    sender = user!()
    conversation = conversation!([sender, user!()])

    # Both eras present: 3 frozen rows (the stuck pre-cutover count), 2 live indexed ones.
    for _ <- 1..3, do: frozen_message!(conversation, sender)
    for _ <- 1..2, do: indexed_message!(conversation, sender)

    {:ok, %{conversations: conversations}} =
      Conversations.admin_list_conversations(%{"app_id" => @tenant})

    row = Enum.find(conversations, &(&1.conversation_id == conversation))
    assert row, "seeded conversation missing from the admin list"

    # 2, not 3, not 5: the frozen rows no longer exist as far as this number is concerned.
    assert row.message_count == 2

    # TRAP 1 — the shape, key-exact. The admin console renders these; `?? 0` turns a missing key
    # into a silent zero, so a shape regression here would never error.
    assert Map.keys(row) |> Enum.sort() ==
             [
               :app_id,
               :conversation_id,
               :last_activity,
               :message_count,
               :participant_count,
               :status,
               :title,
               :type
             ]
             |> Enum.sort()

    assert row.participant_count == 2
  end

  @tag :postgres_integration
  test "admin_user_conversations counts the same way, shape key-exact" do
    me = user!()
    other = user!()
    conversation = conversation!([me, other])

    frozen_message!(conversation, other)
    indexed_message!(conversation, other)
    indexed_message!(conversation, other)
    indexed_message!(conversation, other)

    {:ok, %{conversations: conversations}} =
      Conversations.admin_user_conversations(%{"user_id" => me, "app_id" => @tenant})

    row = Enum.find(conversations, &(&1.conversation_id == conversation))
    assert row, "seeded conversation missing from the admin per-user list"

    assert row.message_count == 3

    assert Map.keys(row) |> Enum.sort() ==
             [
               :conversation_id,
               :last_activity,
               :message_count,
               :other_name,
               :participant_count,
               :status,
               :title,
               :type
             ]
             |> Enum.sort()
  end

  @tag :postgres_integration
  test "a conversation with NO live messages counts 0 — not its frozen history" do
    sender = user!()
    conversation = conversation!([sender, user!()])
    for _ <- 1..4, do: frozen_message!(conversation, sender)

    {:ok, %{conversations: conversations}} =
      Conversations.admin_list_conversations(%{"app_id" => @tenant})

    row = Enum.find(conversations, &(&1.conversation_id == conversation))
    # The number DROPPED at the re-point for pre-cutover-only conversations — the recorded,
    # accepted semantics change (test data; nothing caches or compares it client-side).
    assert row.message_count == 0
  end
end
