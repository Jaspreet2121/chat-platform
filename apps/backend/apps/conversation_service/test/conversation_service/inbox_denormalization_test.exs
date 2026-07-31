defmodule ConversationService.InboxDenormalizationTest do
  @moduledoc """
  READ SIDE of the denormalised inbox row (086). The write side's equivalence proof lives in
  MessageService.InboxProjectionTest; this file proves what @inbox_sql does with the maintained
  columns:

    * the PREVIEW MASK — per-user windows applied to conversation-global columns at read time,
      including the argument's key property: if the newest message is outside a user's window,
      NO older message is shown (nothing older can be inside it);
    * THE FRESHNESS EXCEPTION — a stale `oldest_unread_at` under an auto-delete window triggers an
      inline recount, the row answers with the CORRECT count immediately, and READ-REPAIR persists
      it so the exception stops firing;
    * the exception NEVER fires for trustworthy rows (the happy path stays one lateral-free query —
      asserted by query count, the same telemetry proof the tags slice used);
    * clear_history resets counter + watermark in its own UPDATE;
    * set_auto_delete and participant REACTIVATION recount from source truth.
  """
  use ConversationService.DataCase, async: false

  alias ConversationService.{Conversations, InboxCounters, Participants}

  @app_id "00000000-0000-0000-0000-000000000001"

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
      "INSERT INTO users_auth (id, email, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2, 'x', now(), now())",
      [id, "#{id}@test.local"]
    )

    id
  end

  defp conversation!(members) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, type, created_by, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, 'group', $2::text::uuid, 'active', now(), now())",
      [id, hd(members)]
    )

    # First member is the OWNER — the reactivation test drives the real owner-gated add path.
    for {u, index} <- Enum.with_index(members) do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, $3, now() - interval '2 hours')",
        [id, u, if(index == 0, do: "owner", else: "member")]
      )
    end

    id
  end

  defp message!(conversation_id, sender, body, seconds_ago) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO messages (message_id, conversation_id, sender_user_id, message_type, body, status, created_at, app_id) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, 'text', $4, 'active', now() - make_interval(secs => $5), $6::text::uuid)",
      [id, conversation_id, sender, body, seconds_ago, @app_id]
    )

    InboxCounters.reconcile_conversation(conversation_id)
    id
  end

  defp cp_row(conversation_id, user_id) do
    %{rows: [[unread, oldest]]} =
      Repo.query!(
        "SELECT unread_count, oldest_unread_at FROM conversation_participants " <>
          "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
        [conversation_id, user_id]
      )

    %{unread: unread, oldest: oldest}
  end

  defp row_for(conversation_id, user_id) do
    {:ok, %{rows: rows}} =
      Conversations.inbox_rows(%{"conversation_id" => conversation_id, "user_ids" => [user_id]})

    Enum.find(rows, &(&1.user_id == user_id))
  end

  # --- the preview mask ----------------------------------------------------------------------------

  @tag :postgres_integration
  test "PREVIEW MASK: newest outside the auto-delete window blanks the preview — never an older message" do
    [a, b] = for _ <- 1..2, do: user!()
    conv = conversation!([a, b])

    # Two messages, both older than a 1-hour rolling window.
    message!(conv, a, "ancient", 7_200)
    message!(conv, a, "old", 5_400)

    Repo.query!(
      "UPDATE conversation_participants SET auto_delete_seconds = 3600 " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conv, b]
    )

    InboxCounters.recount(conv, b)

    row = row_for(conv, b)
    # The conversation-global column still holds "old"; b's MASK blanks it (and correctly does not
    # fall back to "ancient" — nothing older than the newest can be inside the window).
    assert row.last_message_preview == nil
    assert row.unread_count == 0

    # a has no window: sees the preview.
    assert row_for(conv, a).last_message_preview == "old"
  end

  @tag :postgres_integration
  test "PREVIEW MASK: cleared_before blanks the preview for the clearer only" do
    [a, b] = for _ <- 1..2, do: user!()
    conv = conversation!([a, b])
    message!(conv, a, "hello", 60)

    {:ok, _} = Participants.clear_history(%{"conversation_id" => conv, "user_id" => b})

    assert row_for(conv, b).last_message_preview == nil
    assert row_for(conv, b).unread_count == 0
    assert row_for(conv, a).last_message_preview == "hello"
  end

  # --- the freshness exception + read-repair -------------------------------------------------------

  @tag :postgres_integration
  test "FRESHNESS EXCEPTION: a stale watermark under auto-delete recounts inline AND read-repairs the row" do
    [a, b] = for _ <- 1..2, do: user!()
    conv = conversation!([a, b])

    # One unread inside a 1-hour window, one outside it.
    message!(conv, a, "aged out", 5_400)
    message!(conv, a, "still fresh", 60)

    Repo.query!(
      "UPDATE conversation_participants SET auto_delete_seconds = 3600 " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conv, b]
    )

    # Manufacture the EXACT stale state the window's movement produces: the counter still says 2
    # (both messages), the watermark still points at the aged-out one. No write ever fixes this —
    # that is the break the pressure test named.
    Repo.query!(
      "UPDATE conversation_participants SET unread_count = 2, " <>
        "oldest_unread_at = now() - make_interval(secs => 5400) " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conv, b]
    )

    # The read answers CORRECTLY (1, not the stale 2) — the inline recount.
    assert row_for(conv, b).unread_count == 1

    # ...and READ-REPAIR persisted the correction: the stored row is fixed and the watermark
    # refreshed, so the exception stops firing.
    repaired = cp_row(conv, b)
    assert repaired.unread == 1
    assert not is_nil(repaired.oldest)

    # Second read: still 1, now from the trusted counter.
    assert row_for(conv, b).unread_count == 1
  end

  @tag :postgres_integration
  test "THE HAPPY PATH STAYS ONE QUERY: no messages access for trusted rows at 50 conversations" do
    a = user!()
    conversations = for _ <- 1..50, do: conversation!([a, user!()])
    # No auto_delete anywhere → every row is trustworthy by construction.

    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:conversation_service, :repo, :query],
      fn _e, _m, _meta, _c -> send(parent, {:q, ref}) end,
      nil
    )

    {:ok, %{conversations: rows}} = Conversations.list_conversations(%{"user_id" => a})
    :telemetry.detach({__MODULE__, ref})

    queries =
      Enum.reduce_while(1..10_000, 0, fn _, acc ->
        receive do
          {:q, ^ref} -> {:cont, acc + 1}
        after
          0 -> {:halt, acc}
        end
      end)

    assert length(rows) == 50
    assert queries == 1, "the denormalised inbox must stay ONE query, got #{queries}"
  end

  # --- recount triggers ----------------------------------------------------------------------------

  @tag :postgres_integration
  test "set_auto_delete recounts: shrinking the window under existing unread corrects the counter" do
    [a, b] = for _ <- 1..2, do: user!()
    conv = conversation!([a, b])

    message!(conv, a, "old unread", 30_000)
    message!(conv, a, "new unread", 60)
    assert cp_row(conv, b).unread == 2

    {:ok, _} =
      Participants.set_auto_delete(%{
        "conversation_id" => conv,
        "user_id" => b,
        "mode" => "8h"
      })

    # The 8-hour window excludes the 30000s-old message; the recount already reflects it.
    assert cp_row(conv, b).unread == 1
  end

  @tag :postgres_integration
  test "REACTIVATION recounts: a rejoining member's counter reflects what accrued while away" do
    [owner, member] = for _ <- 1..2, do: user!()
    conv = conversation!([owner, member])

    # Member leaves; two messages arrive during the absence (raw inserts + reconcile maintain the
    # others' counters; the LEFT row is untouched by design).
    Repo.query!(
      "UPDATE conversation_participants SET left_at = now(), left_reason = 'left', unread_count = 0 " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conv, member]
    )

    message!(conv, owner, "while away 1", 120)
    message!(conv, owner, "while away 2", 60)

    # Rejoin via the REAL reactivation path (owner re-adds a 'left' member).
    {:ok, _} =
      Participants.add_participant(%{
        "conversation_id" => conv,
        "actor_user_id" => owner,
        "user_id" => member
      })

    assert cp_row(conv, member).unread == 2
  end

  @tag :postgres_integration
  test "the reconciler corrects an arbitrarily corrupted row (the mandatory backstop)" do
    [a, b] = for _ <- 1..2, do: user!()
    conv = conversation!([a, b])
    message!(conv, a, "one", 60)

    # Corrupt both directions: counter and preview columns.
    Repo.query!(
      "UPDATE conversation_participants SET unread_count = 99, oldest_unread_at = NULL " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conv, b]
    )

    Repo.query!(
      "UPDATE conversations SET last_message_body = 'corrupted' WHERE id = $1::text::uuid",
      [conv]
    )

    InboxCounters.reconcile_conversation(conv)

    assert cp_row(conv, b).unread == 1
    assert row_for(conv, b).last_message_preview == "one"
  end
end
