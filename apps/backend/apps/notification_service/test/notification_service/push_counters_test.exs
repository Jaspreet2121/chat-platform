defmodule NotificationService.PushCountersTest do
  @moduledoc """
  The push collapse label and app badge, read from the MAINTAINED
  `conversation_participants.unread_count` — the columns the inbox projection increments
  (ledger-idempotent) and the receipt path decrements (`inbox_read_marks`, exactly-once). The old
  inline recount counted the frozen Postgres `messages` table after the cutover, sticking the label
  at "1" and the badge at 0. These tests seed the column directly: the WRITERS are proven in their
  own suites (InboxProjectionTest, the e2e scylla suite) and are deliberately not re-proven here —
  this suite proves the push READS what they maintain.
  """
  use NotificationService.DataCase, async: false

  import ExUnit.CaptureLog

  alias NotificationService.PushContext

  @tenant "00000000-0000-0000-0000-000000000001"

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active')",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp conversation!(creator) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid)",
      [id, @tenant, creator]
    )

    id
  end

  defp participant!(conversation, user, opts \\ []) do
    Repo.query!(
      "INSERT INTO conversation_participants " <>
        "(conversation_id, user_id, role, joined_at, unread_count, left_at, muted_until) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'member', now(), $3, $4, $5)",
      [
        conversation,
        user,
        Keyword.get(opts, :unread_count, 0),
        Keyword.get(opts, :left_at),
        Keyword.get(opts, :muted_until)
      ]
    )

    :ok
  end

  describe "unread_count/2 (the collapse label)" do
    @tag :postgres_integration
    test "(a) reflects the participant's real maintained count" do
      user = user!()
      conversation = conversation!(user!())
      participant!(conversation, user, unread_count: 7)

      assert PushContext.unread_count(conversation, user) == 7
    end

    @tag :postgres_integration
    test "floored at 1: a 0 column and a missing row both label the message being pushed" do
      user = user!()
      conversation = conversation!(user!())
      # The increment is a different consumer group than the push fan-out, so 0 is a legitimate
      # transient state for the very message being announced — the label must not say zero.
      participant!(conversation, user, unread_count: 0)

      assert PushContext.unread_count(conversation, user) == 1
      assert PushContext.unread_count(conversation, Ecto.UUID.generate()) == 1
    end
  end

  describe "total_unread_count/1 (the app badge)" do
    @tag :postgres_integration
    test "(b) sums the maintained column across the user's conversations, excluding LEFT ones" do
      user = user!()
      creator = user!()
      a = conversation!(creator)
      b = conversation!(creator)
      gone = conversation!(creator)

      participant!(a, user, unread_count: 3)
      participant!(b, user, unread_count: 4)
      # A LEFT conversation keeps its last counter value; it must not haunt the badge — the same
      # left_at IS NULL the old query carried in its join.
      participant!(gone, user, unread_count: 50, left_at: DateTime.utc_now())

      assert PushContext.total_unread_count(user) == 7
    end

    @tag :postgres_integration
    test "(c) MUTED conversations still count toward the badge — mute silences the alert, not the count" do
      user = user!()
      creator = user!()
      loud = conversation!(creator)
      muted = conversation!(creator)

      participant!(loud, user, unread_count: 2)

      participant!(muted, user,
        unread_count: 5,
        muted_until: DateTime.add(DateTime.utc_now(), 3600, :second)
      )

      # Preserved behaviour: the old query had no mute filter, matching the app-side reconciler.
      assert PushContext.total_unread_count(user) == 7
    end

    @tag :postgres_integration
    test "(0.5) a user with ZERO participant rows gets badge 0, not a missing value" do
      # SUM over zero rows is NULL; the COALESCE is what turns it into the 0 the payload needs.
      assert PushContext.total_unread_count(Ecto.UUID.generate()) == 0
    end
  end

  describe "error paths (trap-2 decision: degrade WITH a warning, never suppress the push)" do
    @tag :postgres_integration
    test "(d) a failed read degrades to the old fallbacks and logs a warning naming the function" do
      # A malformed uuid makes the cast raise — a real Repo failure, not a stub of one.
      log =
        capture_log(fn ->
          assert PushContext.unread_count("not-a-uuid", "also-not") == 1
        end)

      assert log =~ "push unread_count: read FAILED, degrading to 1"

      log =
        capture_log(fn ->
          assert PushContext.total_unread_count("not-a-uuid") == 0
        end)

      assert log =~ "push total_unread_count: read FAILED, degrading to 0"
    end
  end
end
