defmodule MessageService.SearchVisibilityTest do
  @moduledoc """
  SEARCH: AUTHORIZATION AND VISIBILITY, against a live Postgres.

  This is not a restoration of the old search — it is a PRIVACY FIX. The previous implementation
  filtered on participation and `status <> 'deleted'` and NOTHING ELSE, so it returned hits for
  messages the searcher had cleared, that had aged out of their auto-delete window, or that carried a
  permanent hidden marker. Every one of those was a message the user could not open and should not
  have been shown the text of.

  AUTHORIZATION GETS THE MEDIA-ORACLE STANDARD, because search is the surface where a leak returns
  other people's messages in BULK rather than one at a time: a planted message in a conversation the
  caller is not in must never appear, and that test is mutation-proven by removing the join predicate
  and watching it go red.
  """
  use MessageService.DataCase, async: false

  alias MessageService.MessageStore.PostgresAdapter

  @tenant "00000000-0000-0000-0000-000000000001"

  defp uuid, do: Ecto.UUID.generate()

  # Real rows: conversations.created_by and the participant/hidden-marker user ids all carry FKs to
  # users_auth, so a bare UUID is not a usable stand-in.
  defp user! do
    id = uuid()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active', now(), now())",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp conversation!(id \\ nil) do
    id = id || uuid()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid, now(), now())",
      [id, @tenant, user!()]
    )

    id
  end

  defp participant!(conversation_id, user_id, opts \\ []) do
    Repo.query!(
      "INSERT INTO conversation_participants " <>
        "(conversation_id, user_id, role, joined_at, left_at, cleared_before, auto_delete_seconds) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'member', now(), $3, $4, $5)",
      [
        conversation_id,
        user_id,
        Keyword.get(opts, :left_at),
        Keyword.get(opts, :cleared_before),
        Keyword.get(opts, :auto_delete_seconds)
      ]
    )

    :ok
  end

  defp message!(conversation_id, body, opts \\ []) do
    id = uuid()

    Repo.query!(
      "INSERT INTO messages " <>
        "(message_id, conversation_id, app_id, sender_user_id, message_type, body, status, created_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, $4::text::uuid, 'text', $5, $6, $7)",
      [
        id,
        conversation_id,
        @tenant,
        Keyword.get(opts, :sender) || user!(),
        body,
        Keyword.get(opts, :status, "active"),
        Keyword.get(opts, :created_at) || DateTime.utc_now()
      ]
    )

    id
  end

  defp search(user_id, query) do
    {:ok, %{messages: messages}} =
      PostgresAdapter.search_messages(%{"user_id" => user_id, "query" => query})

    Enum.map(messages, & &1.message_id)
  end

  @tag :postgres_integration
  test "THE ORACLE CASE: a message in a conversation the caller is NOT in never appears" do
    caller = user!()
    stranger_conversation = conversation!()
    participant!(stranger_conversation, user!())
    planted = message!(stranger_conversation, "needle in a private conversation")

    # The caller is in a DIFFERENT conversation containing the same word, so the query itself matches
    # something — a search that returned nothing for unrelated reasons would prove nothing.
    mine = conversation!()
    participant!(mine, caller)
    visible = message!(mine, "needle in my own conversation")

    found = search(caller, "needle")

    assert visible in found
    refute planted in found, "SEARCH LEAKED a message from a conversation the caller is not in"
  end

  @tag :postgres_integration
  test "NO MEMBERSHIP AT ALL denies everything — an empty participant set is not a wildcard" do
    orphan = user!()
    conversation = conversation!()
    participant!(conversation, user!())
    message!(conversation, "needle nobody should see")

    assert search(orphan, "needle") == []
  end

  @tag :postgres_integration
  test "a participant who LEFT loses access to what they could previously search" do
    user = user!()
    conversation = conversation!()
    participant!(conversation, user, left_at: DateTime.utc_now())
    message!(conversation, "needle from before they left")

    assert search(user, "needle") == []
  end

  @tag :postgres_integration
  test "PRIVACY FIX 1: cleared_before hides messages the old search returned" do
    user = user!()
    conversation = conversation!()
    cutoff = DateTime.utc_now()

    older =
      message!(conversation, "needle before the clear", created_at: DateTime.add(cutoff, -60))

    newer = message!(conversation, "needle after the clear", created_at: DateTime.add(cutoff, 60))

    participant!(conversation, user, cleared_before: cutoff)

    found = search(user, "needle")

    assert newer in found
    refute older in found, "a cleared message must not be searchable — the old query returned it"
  end

  @tag :postgres_integration
  test "PRIVACY FIX 2: the rolling auto-delete window hides aged-out messages" do
    user = user!()
    conversation = conversation!()

    aged =
      message!(conversation, "needle long gone",
        created_at: DateTime.add(DateTime.utc_now(), -3600)
      )

    fresh = message!(conversation, "needle still here")

    # 10-minute window: `aged` is an hour old and has disappeared for this user.
    participant!(conversation, user, auto_delete_seconds: 600)

    found = search(user, "needle")

    assert fresh in found
    refute aged in found, "an auto-deleted message must not be searchable"
  end

  @tag :postgres_integration
  test "PRIVACY FIX 3: a permanent user_hidden_messages marker hides the message" do
    user = user!()
    conversation = conversation!()
    participant!(conversation, user)

    hidden = message!(conversation, "needle deleted for me")
    kept = message!(conversation, "needle still visible")

    Repo.query!(
      "INSERT INTO user_hidden_messages (user_id, message_id, hidden_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, now())",
      [user, hidden]
    )

    found = search(user, "needle")

    assert kept in found
    refute hidden in found, "a delete-for-me message must not be searchable"
  end

  @tag :postgres_integration
  test "SCOPING: the hidden marker is PER USER — one user hiding does not hide for another" do
    hider = user!()
    other = user!()
    conversation = conversation!()
    participant!(conversation, hider)
    participant!(conversation, other)

    message_id = message!(conversation, "needle one user hid")

    Repo.query!(
      "INSERT INTO user_hidden_messages (user_id, message_id, hidden_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, now())",
      [hider, message_id]
    )

    refute message_id in search(hider, "needle")

    assert message_id in search(other, "needle"),
           "one user's hide must not affect another's search"
  end

  @tag :postgres_integration
  test "a soft-deleted message never appears (unchanged behaviour, asserted so it stays true)" do
    user = user!()
    conversation = conversation!()
    participant!(conversation, user)

    deleted = message!(conversation, "needle deleted for everyone", status: "deleted")
    kept = message!(conversation, "needle alive")

    found = search(user, "needle")

    assert kept in found
    refute deleted in found
  end

  @tag :postgres_integration
  test "AFTER-VIEWING accepts inbox_read_marks as seen-evidence — the Scylla-era receipt record" do
    # Under the Scylla store, read receipts are CQL writes and the Postgres message_receipts table is
    # FROZEN — with receipts as the only evidence, this predicate fails open and an after-viewing
    # message the user already read keeps surfacing in global reads. inbox_read_marks is written by
    # record_read_once/4 (exactly "first-time reads under Scylla", in Postgres), so it is the second
    # evidence source. One definition in VisibilityWindow; this test guards the second source.
    searcher = user!()
    conversation = conversation!()

    Repo.query!(
      "INSERT INTO conversation_participants " <>
        "(conversation_id, user_id, role, joined_at, disappear_after_viewing_since) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'member', now(), now() - interval '1 hour')",
      [conversation, searcher]
    )

    seen = message!(conversation, "vanishing seen needle")
    unseen = message!(conversation, "vanishing unseen needle")

    # The read happened under the SCYLLA store: no message_receipts row, only a read mark.
    Repo.query!(
      "INSERT INTO inbox_read_marks (conversation_id, message_id, user_id) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid)",
      [conversation, seen, searcher]
    )

    results = search(searcher, "vanishing")

    # The unseen message still surfaces; the seen one is gone — evidenced by the mark alone.
    assert unseen in results
    refute seen in results
  end
end
