defmodule MessageService.PinsTest do
  @moduledoc """
  PINNED MESSAGES (092) against a live Postgres.

  The load-bearing test here is THE PER-USER MASK. A pin is per-conversation, but `cleared_before`,
  the rolling auto-delete window and `user_hidden_messages` are per-user — so two people in the same
  group can legitimately see different pinned bars. Remove the mask and you resurrect messages a user
  cleared or that auto-deleted for them, which is exactly the bug message search shipped with.
  """
  use MessageService.DataCase, async: false

  alias MessageService.Pins

  @tenant "00000000-0000-0000-0000-000000000001"

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

  defp conversation! do
    id = uuid()

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

  defp message!(conversation_id, opts \\ []) do
    id = uuid()

    Repo.query!(
      "INSERT INTO messages " <>
        "(message_id, conversation_id, app_id, sender_user_id, message_type, body, status, created_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, $4::text::uuid, 'text', 'hi', $5, $6)",
      [
        id,
        conversation_id,
        @tenant,
        Keyword.get(opts, :sender) || user!(),
        Keyword.get(opts, :status, "active"),
        Keyword.get(opts, :created_at) || DateTime.utc_now()
      ]
    )

    id
  end

  defp pin!(conversation_id, message_id, user_id) do
    Pins.pin_message(%{
      "conversation_id" => conversation_id,
      "message_id" => message_id,
      "user_id" => user_id
    })
  end

  defp visible_pins(conversation_id, viewer) do
    {:ok, %{pins: pins}} =
      Pins.list_pins(%{"conversation_id" => conversation_id, "user_id" => viewer})

    Enum.map(pins, & &1.message_id)
  end

  @tag :postgres_integration
  test "pins are per-CONVERSATION: everyone in the group sees the same pin by default" do
    conversation = conversation!()
    a = user!()
    b = user!()
    participant!(conversation, a)
    participant!(conversation, b)

    message = message!(conversation)
    assert {:ok, %{pinned: true}} = pin!(conversation, message, a)

    # If this were per-user (a bookmark), b would see nothing. Bookmarks already exist as stars.
    assert visible_pins(conversation, a) == [message]
    assert visible_pins(conversation, b) == [message]
  end

  @tag :postgres_integration
  test "the cap holds, and re-pinning does not consume budget" do
    conversation = conversation!()
    user = user!()
    participant!(conversation, user)

    pinned = for _ <- 1..Pins.max_pins(), do: message!(conversation)
    for m <- pinned, do: assert({:ok, _} = pin!(conversation, m, user))

    # One over the cap.
    assert {:error, :pin_limit} = pin!(conversation, message!(conversation), user)

    # Re-pinning an ALREADY-pinned message is idempotent and must not be refused as over-cap.
    assert {:ok, %{pinned: true}} = pin!(conversation, hd(pinned), user)
    assert length(visible_pins(conversation, user)) == Pins.max_pins()
  end

  @tag :postgres_integration
  test "unpin frees budget and is idempotent" do
    conversation = conversation!()
    user = user!()
    participant!(conversation, user)

    pinned = for _ <- 1..Pins.max_pins(), do: message!(conversation)
    for m <- pinned, do: pin!(conversation, m, user)

    assert {:ok, %{pinned: false}} =
             Pins.unpin_message(%{"conversation_id" => conversation, "message_id" => hd(pinned)})

    # Idempotent — unpinning something not pinned succeeds.
    assert {:ok, %{pinned: false}} =
             Pins.unpin_message(%{"conversation_id" => conversation, "message_id" => hd(pinned)})

    assert {:ok, _} = pin!(conversation, message!(conversation), user)
  end

  @tag :postgres_integration
  test "a message from ANOTHER conversation cannot be pinned into this one" do
    mine = conversation!()
    theirs = conversation!()
    user = user!()
    participant!(mine, user)

    stranger_message = message!(theirs)

    # Without the conversation check inside pin_message/1, a caller who is admin of `mine` could pin a
    # message out of a conversation they are not in — the gateway only checked their role in `mine`.
    assert {:error, :message_not_found} = pin!(mine, stranger_message, user)
  end

  @tag :postgres_integration
  test "a DELETED message leaves the pinned list, and frees the cap" do
    conversation = conversation!()
    user = user!()
    participant!(conversation, user)

    message = message!(conversation)
    pin!(conversation, message, user)
    assert visible_pins(conversation, user) == [message]

    # The read filter alone must hide it, even before unpin_deleted/1 runs — a pinned tombstone is
    # worse than no pin at all.
    Repo.query!(
      "UPDATE messages SET status = 'deleted', deleted_at = now() WHERE message_id = $1::text::uuid",
      [message]
    )

    assert visible_pins(conversation, user) == []

    # And the write path frees the budget so a deleted message does not hold a slot forever.
    assert :ok = Pins.unpin_deleted(message)
    for _ <- 1..Pins.max_pins(), do: assert({:ok, _} = pin!(conversation, message!(conversation), user))
  end

  @tag :postgres_integration
  test "a pin SURVIVES the pinner leaving — it is a conversation artifact, not theirs" do
    conversation = conversation!()
    pinner = user!()
    other = user!()
    participant!(conversation, pinner)
    participant!(conversation, other)

    message = message!(conversation)
    pin!(conversation, message, pinner)

    Repo.query!(
      "UPDATE conversation_participants SET left_at = now() " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conversation, pinner]
    )

    # Leaving does not unwind actions you took, matching how blocks and group renames behave.
    assert visible_pins(conversation, other) == [message]
  end

  @tag :postgres_integration
  test "THE MASK: cleared_before hides a pin from ONE user and not the other" do
    conversation = conversation!()
    cutoff = DateTime.utc_now()
    old_message = message!(conversation, created_at: DateTime.add(cutoff, -60))

    sees = user!()
    cleared = user!()
    participant!(conversation, sees)
    participant!(conversation, cleared, cleared_before: cutoff)

    pin!(conversation, old_message, sees)

    # TWO PEOPLE IN THE SAME GROUP, DIFFERENT PINNED BARS. This is the intended behaviour: a pin does
    # not override a user's own clear.
    assert visible_pins(conversation, sees) == [old_message]
    assert visible_pins(conversation, cleared) == []
  end

  @tag :postgres_integration
  test "THE MASK: an auto-deleted message is not resurrected by being pinned" do
    conversation = conversation!()
    aged = message!(conversation, created_at: DateTime.add(DateTime.utc_now(), -3600))

    sees = user!()
    expired = user!()
    participant!(conversation, sees)
    participant!(conversation, expired, auto_delete_seconds: 600)

    pin!(conversation, aged, sees)

    assert visible_pins(conversation, sees) == [aged]
    assert visible_pins(conversation, expired) == []
  end

  @tag :postgres_integration
  test "THE MASK: a delete-for-me marker hides a pin from that user only" do
    conversation = conversation!()
    message = message!(conversation)

    sees = user!()
    hider = user!()
    participant!(conversation, sees)
    participant!(conversation, hider)

    pin!(conversation, message, sees)

    Repo.query!(
      "INSERT INTO user_hidden_messages (user_id, message_id, hidden_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, now())",
      [hider, message]
    )

    assert visible_pins(conversation, sees) == [message]
    assert visible_pins(conversation, hider) == []
  end

  @tag :postgres_integration
  test "a NON-PARTICIPANT sees no pins even if they ask directly" do
    conversation = conversation!()
    participant!(conversation, user!())
    message = message!(conversation)
    pin!(conversation, message, user!())

    assert visible_pins(conversation, user!()) == []
  end
end
