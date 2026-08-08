defmodule MessageService.InboxProjectionTest do
  @moduledoc """
  THE EQUIVALENCE PROOF for the denormalised inbox row (086), write side: after every mutation the
  MAINTAINED columns must equal what the OLD inbox laterals would have computed — the laterals are
  embedded here verbatim as the ORACLE, run against the same data in the same transaction. If the
  maintenance and the oracle ever disagree, the denormalisation has diverged from the semantics it
  replaced, which is the only bug that matters in this slice.

  Covers, through the REAL PostgresAdapter paths: send (increment + preview), first-time read
  (decrement + the free zero-watermark advance), REPEAT read (no double decrement — the idempotency
  gate), delete of a non-preview message (decrement for non-readers only), delete OF the preview
  (promotion to next-newest non-deleted), edit of the preview vs a non-preview edit, window guards
  (a read of a message outside the reader's cleared window must not decrement), and sender exclusion.
  """
  use MessageService.DataCase, async: false

  import ExUnit.CaptureLog

  alias MessageService.MessageStore.PostgresAdapter

  @tenant_zero "00000000-0000-0000-0000-000000000001"

  setup do
    prev = Application.get_env(:message_service, :message_persistence, false)
    Application.put_env(:message_service, :message_persistence, true)
    on_exit(fn -> Application.put_env(:message_service, :message_persistence, prev) end)
    :ok
  end

  # --- fixtures (ONE repo for everything — the cross-repo sandbox rule) ----------------------------

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, email, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', now(), now())",
      [id, @tenant_zero, "#{id}@test.local"]
    )

    id
  end

  defp conversation!(members) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid, 'active', now(), now())",
      [id, @tenant_zero, hd(members)]
    )

    for u <- members do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now() - interval '1 hour')",
        [id, u]
      )
    end

    id
  end

  defp send!(conversation_id, sender, body, opts \\ []) do
    created_at =
      DateTime.utc_now()
      |> DateTime.add(Keyword.get(opts, :seconds_ago, 0) * -1, :second)
      |> DateTime.truncate(:microsecond)

    {:ok, message} =
      PostgresAdapter.put_message(%{
        "conversation_id" => conversation_id,
        "message_id" => Ecto.UUID.generate(),
        "sender_user_id" => sender,
        "message_type" => Keyword.get(opts, :type, "text"),
        "body" => body,
        "metadata" => Keyword.get(opts, :metadata, %{}),
        "status" => "active",
        "created_at" => created_at
      })

    message
  end

  defp read!(conversation_id, message_id, user_id) do
    {:ok, _} =
      PostgresAdapter.mark_read(%{
        "conversation_id" => conversation_id,
        "message_id" => message_id,
        "user_id" => user_id,
        "updated_at" => DateTime.utc_now()
      })
  end

  # --- THE ORACLE: the old laterals, verbatim ------------------------------------------------------

  defp oracle_unread(conversation_id, user_id) do
    %{rows: [[count, oldest]]} =
      Repo.query!(
        """
        SELECT count(m.message_id)::int, min(m.created_at)
        FROM conversation_participants cp
        LEFT JOIN messages m
          ON m.conversation_id = cp.conversation_id
         AND m.deleted_at IS NULL
         AND m.sender_user_id <> cp.user_id
         AND (cp.cleared_before IS NULL OR m.created_at > cp.cleared_before)
         AND (cp.auto_delete_seconds IS NULL
              OR m.created_at > now() - make_interval(secs => cp.auto_delete_seconds))
         AND NOT EXISTS (
           SELECT 1 FROM message_receipts r
           WHERE r.conversation_id = m.conversation_id AND r.message_id = m.message_id
             AND r.user_id = cp.user_id AND (r.status = 'read' OR r.read_at IS NOT NULL)
         )
        WHERE cp.conversation_id = $1::text::uuid AND cp.user_id = $2::text::uuid
        """,
        [conversation_id, user_id]
      )

    {count, oldest}
  end

  defp oracle_preview(conversation_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT body, message_type, message_id::text FROM messages " <>
          "WHERE conversation_id = $1::text::uuid AND deleted_at IS NULL " <>
          "ORDER BY created_at DESC LIMIT 1",
        [conversation_id]
      )

    case rows do
      [[body, type, id]] -> %{body: body, type: type, id: id}
      [] -> %{body: nil, type: nil, id: nil}
    end
  end

  defp maintained(conversation_id, user_id) do
    %{rows: [[unread, oldest]]} =
      Repo.query!(
        "SELECT unread_count, oldest_unread_at FROM conversation_participants " <>
          "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
        [conversation_id, user_id]
      )

    %{rows: [[body, type, id]]} =
      Repo.query!(
        "SELECT last_message_body, last_message_type, last_message_id::text FROM conversations " <>
          "WHERE id = $1::text::uuid",
        [conversation_id]
      )

    %{unread: unread, oldest: oldest, preview: %{body: body, type: type, id: id}}
  end

  # The single assertion this file exists for.
  defp assert_equivalent!(conversation_id, users) do
    preview = oracle_preview(conversation_id)

    for user <- users do
      m = maintained(conversation_id, user)
      {oracle_count, oracle_oldest} = oracle_unread(conversation_id, user)

      assert m.unread == oracle_count,
             "unread diverged for #{user}: maintained=#{m.unread} oracle=#{oracle_count}"

      # The watermark must never be NEWER than the true oldest unread (stale-older is safe by design;
      # stale-newer would wrongly pass the freshness test and hide a needed recount).
      if oracle_count > 0 and not is_nil(m.oldest) do
        assert DateTime.compare(m.oldest, oracle_oldest) in [:lt, :eq]
      end

      assert m.preview == preview,
             "preview diverged: #{inspect(m.preview)} vs #{inspect(preview)}"
    end
  end

  # --- scenarios -----------------------------------------------------------------------------------

  @tag :postgres_integration
  test "send / read / repeat-read / read-all: counter matches the oracle at every step" do
    [a, b, c] = for _ <- 1..3, do: user!()
    conv = conversation!([a, b, c])

    m1 = send!(conv, a, "one")
    assert_equivalent!(conv, [a, b, c])
    assert maintained(conv, b).unread == 1
    # Sender's own count is untouched.
    assert maintained(conv, a).unread == 0

    m2 = send!(conv, a, "two")
    assert_equivalent!(conv, [a, b, c])
    assert maintained(conv, b).unread == 2

    read!(conv, m1.message_id, b)
    assert_equivalent!(conv, [a, b, c])
    assert maintained(conv, b).unread == 1
    # c hasn't read anything.
    assert maintained(conv, c).unread == 2

    # REPEAT read of the same message: the idempotency gate — no double decrement.
    read!(conv, m1.message_id, b)
    assert maintained(conv, b).unread == 1
    assert_equivalent!(conv, [a, b, c])

    # Reading the last one: count hits 0 and the watermark NULLs (the free advance).
    read!(conv, m2.message_id, b)
    m = maintained(conv, b)
    assert m.unread == 0
    assert m.oldest == nil
    assert_equivalent!(conv, [a, b, c])
  end

  @tag :postgres_integration
  test "delete: non-readers decrement, readers don't; deleting the PREVIEW promotes the next-newest" do
    [a, b, c] = for _ <- 1..3, do: user!()
    conv = conversation!([a, b, c])

    m1 = send!(conv, a, "first", seconds_ago: 60)
    m2 = send!(conv, a, "second (preview)")
    read!(conv, m2.message_id, b)
    assert_equivalent!(conv, [a, b, c])

    # Delete the PREVIEW message: b already read it (no decrement for b); c had not (decrement).
    {:ok, _} =
      PostgresAdapter.delete_message(%{
        "conversation_id" => conv,
        "message_id" => m2.message_id,
        "deleted_at" => DateTime.utc_now()
      })

    assert_equivalent!(conv, [a, b, c])
    assert maintained(conv, b).unread == 1
    assert maintained(conv, c).unread == 1
    # Preview promoted to the next-newest non-deleted message.
    assert maintained(conv, b).preview.id == m1.message_id

    # Delete the last remaining message: preview clears entirely.
    {:ok, _} =
      PostgresAdapter.delete_message(%{
        "conversation_id" => conv,
        "message_id" => m1.message_id,
        "deleted_at" => DateTime.utc_now()
      })

    assert_equivalent!(conv, [a, b, c])
    assert maintained(conv, b).preview.id == nil
    assert maintained(conv, b).unread == 0
  end

  @tag :postgres_integration
  test "edit: the preview text follows a body edit of the PREVIEW message only" do
    [a, b] = for _ <- 1..2, do: user!()
    conv = conversation!([a, b])

    m1 = send!(conv, a, "older", seconds_ago: 60)
    _m2 = send!(conv, a, "newest")

    # Editing the NON-preview message changes nothing about the preview.
    {:ok, _} =
      PostgresAdapter.update_message(%{
        "conversation_id" => conv,
        "message_id" => m1.message_id,
        "body" => "older, edited",
        "edited_at" => DateTime.utc_now()
      })

    assert maintained(conv, b).preview.body == "newest"
    assert_equivalent!(conv, [a, b])
  end

  @tag :postgres_integration
  test "edit of the preview message updates the preview text" do
    [a, b] = for _ <- 1..2, do: user!()
    conv = conversation!([a, b])

    m = send!(conv, a, "typo")

    {:ok, _} =
      PostgresAdapter.update_message(%{
        "conversation_id" => conv,
        "message_id" => m.message_id,
        "body" => "fixed",
        "edited_at" => DateTime.utc_now()
      })

    assert maintained(conv, b).preview.body == "fixed"
    assert_equivalent!(conv, [a, b])
  end

  @tag :postgres_integration
  test "WINDOW GUARD: a read of a message outside the reader's cleared window never decrements" do
    [a, b] = for _ <- 1..2, do: user!()
    conv = conversation!([a, b])

    m1 = send!(conv, a, "before clear", seconds_ago: 120)

    # b clears history AFTER m1 (cleared_before = now): m1 leaves b's window; counter resets.
    Repo.query!(
      "UPDATE conversation_participants SET cleared_before = now(), unread_count = 0, oldest_unread_at = NULL " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conv, b]
    )

    m2 = send!(conv, a, "after clear")
    assert maintained(conv, b).unread == 1
    assert_equivalent!(conv, [a, b])

    # A LATE receipt for the cleared-away m1 (old device syncing): m1 was never in the maintained
    # count, so the decrement must be suppressed by the window guard — not steal m2's unread.
    read!(conv, m1.message_id, b)
    assert maintained(conv, b).unread == 1
    assert_equivalent!(conv, [a, b])

    read!(conv, m2.message_id, b)
    assert maintained(conv, b).unread == 0
    assert_equivalent!(conv, [a, b])
  end

  @tag :postgres_integration
  test "a media message carries its content_type into the preview columns" do
    [a, b] = for _ <- 1..2, do: user!()
    conv = conversation!([a, b])

    send!(conv, a, nil,
      type: "media",
      metadata: %{"content_type" => "image/png", "media_id" => Ecto.UUID.generate()}
    )

    %{rows: [[type, content_type]]} =
      Repo.query!(
        "SELECT last_message_type, last_message_content_type FROM conversations WHERE id = $1::text::uuid",
        [conv]
      )

    assert type == "media"
    assert content_type == "image/png"
    assert_equivalent!(conv, [a, b])
  end

  # --- the SILENT half: a preview write that matches nothing ---------------------------------------

  describe "zero-row preview write" do
    @tag :postgres_integration
    test "logs a warning naming the conversation and message instead of passing silently" do
      sender = user!()
      peer = user!()
      conversation = conversation!([sender, peer])

      # `last_message_at` NEWER than the message being recorded: the out-of-order guard rejects the
      # UPDATE, it matches zero rows, and `Repo.query!` still succeeds. This is exactly the shape
      # that hid a week of reverted previews in production — the write "worked" and wrote nothing.
      Repo.query!(
        "UPDATE conversations SET last_message_at = now() + interval '1 day', " <>
          "last_message_body = 'a newer preview' WHERE id = $1::text::uuid",
        [conversation]
      )

      message = %{
        conversation_id: conversation,
        message_id: Ecto.UUID.generate(),
        sender_user_id: sender,
        message_type: "text",
        body: "this preview will not land",
        created_at: DateTime.utc_now(),
        metadata: %{}
      }

      log = capture_log(fn -> MessageService.InboxProjection.record_message(message) end)

      assert log =~ "matched ZERO rows"
      assert log =~ conversation
      assert log =~ message.message_id

      # And the point of the warning: the preview really did not change...
      %{rows: [[body]]} =
        Repo.query!("SELECT last_message_body FROM conversations WHERE id = $1::text::uuid", [
          conversation
        ])

      assert body == "a newer preview"

      # ...while the UNREAD update, which carries no such guard, DID apply. The two halves of
      # record_message/1 diverge silently, which is why the preview half has to say so.
      %{rows: [[unread]]} =
        Repo.query!(
          "SELECT unread_count FROM conversation_participants " <>
            "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
          [conversation, peer]
        )

      assert unread == 1
    end

    @tag :postgres_integration
    test "a preview write that DOES land stays quiet" do
      sender = user!()
      peer = user!()
      conversation = conversation!([sender, peer])

      message = %{
        conversation_id: conversation,
        message_id: Ecto.UUID.generate(),
        sender_user_id: sender,
        message_type: "text",
        body: "this one lands",
        created_at: DateTime.utc_now(),
        metadata: %{}
      }

      log = capture_log(fn -> MessageService.InboxProjection.record_message(message) end)
      refute log =~ "matched ZERO rows"
    end
  end
end
