defmodule MessageService.DmStreaksTest do
  @moduledoc """
  Server-authoritative DM streaks (125) on the REAL create path and real rows.

  The four rules that matter: a day counts only when BOTH sides sent (MUT-1), consecutive counted
  days increment while a GAP resets to 1 (MUT-2), a second message the same day changes nothing
  (MUT-5), and a GROUP never gets a row at all (MUT-6). The day boundary is the sender's, and the
  tests drive it by moving the stored dates rather than the clock.
  """
  use MessageService.DataCase, async: false

  import ExUnit.CaptureLog

  alias MessageService.{DmStreaks, Messages}

  @tenant "00000000-0000-0000-0000-000000000001"

  setup do
    prev = Application.get_env(:message_service, :message_persistence, false)

    prev_adapter =
      Application.get_env(
        :message_service,
        :message_store_adapter,
        MessageService.MessageStore.QueryPlanAdapter
      )

    Application.put_env(:message_service, :message_persistence, true)

    Application.put_env(
      :message_service,
      :message_store_adapter,
      MessageService.MessageStore.PostgresAdapter
    )

    on_exit(fn ->
      Application.put_env(:message_service, :message_persistence, prev)
      Application.put_env(:message_service, :message_store_adapter, prev_adapter)
    end)

    :ok
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active', now(), now())",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp conversation!(type, members) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, $4::text::uuid, 'active', now(), now())",
      [id, @tenant, type, hd(members)]
    )

    for member <- members do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
        [id, member]
      )
    end

    id
  end

  defp dm! do
    a = user!()
    b = user!()
    {conversation!("direct", [a, b]), a, b}
  end

  defp send!(conversation_id, sender, body \\ "hi") do
    {:ok, message} =
      Messages.create_message(%{
        "conversation_id" => conversation_id,
        "sender_user_id" => sender,
        "message_type" => "text",
        "body" => body
      })

    message
  end

  defp streak(conversation_id) do
    case Repo.query!(
           "SELECT streak_days, last_both_sides_date FROM dm_streaks WHERE conversation_id = $1::text::uuid",
           [conversation_id]
         ) do
      %{rows: [[days, date]]} -> {days, date}
      %{rows: []} -> :none
    end
  end

  # Move the whole conversation's bookkeeping back by `days`, so the NEXT send lands on a later day
  # without touching the clock.
  defp age!(conversation_id, days) do
    Repo.query!(
      "UPDATE dm_streaks SET last_both_sides_date = last_both_sides_date - $2::int " <>
        "WHERE conversation_id = $1::text::uuid",
      [conversation_id, days]
    )

    Repo.query!(
      "UPDATE conversation_participants SET last_message_on = last_message_on - $2::int " <>
        "WHERE conversation_id = $1::text::uuid AND last_message_on IS NOT NULL",
      [conversation_id, days]
    )
  end

  @tag :postgres_integration
  test "MUT-1 guard: a ONE-SIDED day never counts; the streak starts only when both sides have sent" do
    {dm, a, b} = dm!()

    log = capture_log([level: :info], fn -> send!(dm, a) end)
    assert log =~ "dm streak skipped conversation=#{dm} reason=not_both_sides"
    assert streak(dm) == :none

    # A SECOND message from the same side is still one-sided.
    log = capture_log([level: :info], fn -> send!(dm, a, "still me") end)
    assert log =~ "reason=not_both_sides"
    assert streak(dm) == :none

    log = capture_log([level: :info], fn -> send!(dm, b) end)
    assert log =~ "dm streak updated conversation=#{dm} days=1"
    assert {1, %Date{}} = streak(dm)
  end

  @tag :postgres_integration
  test "MUT-5 guard: more messages the SAME day change nothing" do
    {dm, a, b} = dm!()
    send!(dm, a)
    send!(dm, b)
    assert {1, today} = streak(dm)

    log =
      capture_log([level: :info], fn ->
        send!(dm, a, "again")
        send!(dm, b, "and again")
      end)

    assert log =~ "reason=same_day"
    assert streak(dm) == {1, today}
  end

  @tag :postgres_integration
  test "MUT-2 guard: consecutive days increment, and a GAP resets to 1" do
    {dm, a, b} = dm!()

    send!(dm, a)
    send!(dm, b)
    assert {1, _} = streak(dm)

    # Yesterday's count + today's both-sides day → 2.
    age!(dm, 1)
    send!(dm, a)
    send!(dm, b)
    assert {2, _} = streak(dm)

    age!(dm, 1)
    send!(dm, a)
    send!(dm, b)
    assert {3, _} = streak(dm)

    # A GAP: the last counted day is now three days back, so the next counted day starts over.
    age!(dm, 3)
    send!(dm, a)
    send!(dm, b)
    assert {1, _} = streak(dm)
  end

  @tag :postgres_integration
  test "MUT-6 guard: a GROUP conversation never gets a streak row" do
    a = user!()
    b = user!()
    c = user!()
    group = conversation!("group", [a, b, c])

    send!(group, a)
    send!(group, b)
    send!(group, c)

    assert streak(group) == :none
  end

  @tag :postgres_integration
  test "a member who LEFT is not a side that must message" do
    a = user!()
    b = user!()
    dm = conversation!("direct", [a, b])

    Repo.query!(
      "UPDATE conversation_participants SET left_at = now() " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [dm, b]
    )

    # With b gone, a's own send is the only active side — and it counts.
    send!(dm, a)
    assert {1, _} = streak(dm)
  end

  describe "the day boundary" do
    test "no client offset → UTC, logged once per path" do
      log = capture_log([level: :info], fn -> DmStreaks.local_today(%{}, "conv-1") end)
      assert log =~ "dm streak day=utc conversation=conv-1 reason=no_client_offset"
      assert DmStreaks.local_today(%{}) == DateTime.to_date(DateTime.utc_now())

      # Once per path: the same decision does not re-log.
      log = capture_log([level: :info], fn -> DmStreaks.local_today(%{}, "conv-1") end)
      refute log =~ "dm streak day=utc"
    end

    test "a client offset moves the day, and is logged with its value" do
      log =
        capture_log([level: :info], fn ->
          DmStreaks.local_today(%{"tz_offset_minutes" => 330}, "conv-2")
        end)

      assert log =~ "dm streak day=client_offset conversation=conv-2 offset_minutes=330"

      # 23:30 UTC is already TOMORROW at +05:30 — the case a UTC-only server gets wrong every night.
      late = ~U[2026-09-17 23:30:00Z]
      assert DateTime.to_date(late) == ~D[2026-09-17]

      assert DateTime.to_date(DateTime.add(late, 330 * 60, :second)) == ~D[2026-09-18]
    end

    test "an absurd offset is ignored rather than honoured — a caller must not pick their own day" do
      today = DateTime.to_date(DateTime.utc_now())
      assert DmStreaks.local_today(%{"tz_offset_minutes" => 99_999}) == today
      assert DmStreaks.local_today(%{"tz_offset_minutes" => "not a number"}) == today
      # A string offset a client sends as JSON text still works.
      assert DmStreaks.local_today(%{"tz_offset_minutes" => "0"}) == today
    end
  end
end
