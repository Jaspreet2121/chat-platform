defmodule RealtimeGateway.AutoReplyTest do
  @moduledoc """
  The auto-reply DECISION CORE (102), pure: every hard skip, the audience matrix, greeting
  first-message/idle rules, the away schedule (timezone shift, midnight-crossing ranges, ISO day
  boundaries), and both-due → greeting only.
  """
  use ExUnit.Case, async: true

  alias RealtimeGateway.AutoReply

  @sender "11111111-1111-1111-1111-111111111111"
  @recipient "22222222-2222-2222-2222-222222222222"

  defp context(overrides \\ %{}) do
    Map.merge(
      %{
        conversation_type: "direct",
        sender_id: @sender,
        recipient_id: @recipient,
        sender_auto?: false,
        blocked?: false,
        settings: %{away: %{}, greeting: %{}},
        contact?: false,
        last_activity_at: nil,
        now: ~U[2026-08-26 10:00:00Z]
      },
      overrides
    )
  end

  defp away(overrides \\ %{}) do
    Map.merge(
      %{"enabled" => true, "mode" => "always", "audience" => "everyone", "body" => "Away!"},
      overrides
    )
  end

  defp greeting(overrides \\ %{}) do
    Map.merge(
      %{
        "enabled" => true,
        "audience" => "everyone",
        "body" => "Hello!",
        "resend_after_days" => 14
      },
      overrides
    )
  end

  test "every HARD SKIP, in order: group, self, automated inbound (loop-proof), blocked, disabled" do
    live = %{settings: %{away: away(), greeting: greeting()}}

    assert AutoReply.decide(context(Map.merge(live, %{conversation_type: "group"}))) == :skip
    assert AutoReply.decide(context(Map.merge(live, %{sender_id: @recipient}))) == :skip
    # THE LOOP-PROOF: an inbound message carrying the auto flag never triggers a reply — our own
    # replies always carry it, so auto can never answer auto.
    assert AutoReply.decide(context(Map.merge(live, %{sender_auto?: true}))) == :skip
    assert AutoReply.decide(context(Map.merge(live, %{blocked?: true}))) == :skip
    assert AutoReply.decide(context()) == :skip

    assert AutoReply.decide(context(live)) == {:send, :greeting}
  end

  test "SECRET CHATS (108): a secret conversation is a hard skip — even with both features live" do
    live = context(%{settings: %{away: away(), greeting: greeting()}})
    assert AutoReply.decide(live) == {:send, :greeting}

    assert AutoReply.decide(Map.put(live, :conversation_secret?, true)) == :skip
    # Explicit boolean discipline: absent or non-true never skips.
    assert AutoReply.decide(Map.put(live, :conversation_secret?, false)) == {:send, :greeting}
  end

  test "BOTH DUE → greeting only; away alone → away" do
    both = context(%{settings: %{away: away(), greeting: greeting()}})
    assert AutoReply.decide(both) == {:send, :greeting}

    away_only = context(%{settings: %{away: away(), greeting: %{}}})
    assert AutoReply.decide(away_only) == {:send, :away}
  end

  test "AUDIENCE MATRIX: all four audiences × contact / non-contact / excepted sender" do
    for {audience, contact?, expected} <- [
          {"everyone", false, true},
          {"everyone", true, true},
          {"contacts", true, true},
          {"contacts", false, false},
          {"non_contacts", false, true},
          {"non_contacts", true, false},
          {"except", false, true}
        ] do
      decision =
        AutoReply.decide(
          context(%{
            settings: %{away: away(%{"audience" => audience}), greeting: %{}},
            contact?: contact?
          })
        )

      assert decision == {:send, :away} == expected,
             "audience=#{audience} contact=#{contact?} → #{inspect(decision)}"
    end

    # except: a listed sender is excluded; everyone else replies.
    excepted = away(%{"audience" => "except", "except_ids" => [@sender]})
    assert AutoReply.decide(context(%{settings: %{away: excepted, greeting: %{}}})) == :skip
  end

  test "GREETING: due on first message (nil last activity) and after the idle window; not while active" do
    settings = %{away: %{}, greeting: greeting(%{"resend_after_days" => 14})}

    assert AutoReply.decide(context(%{settings: settings, last_activity_at: nil})) ==
             {:send, :greeting}

    idle = DateTime.add(~U[2026-08-26 10:00:00Z], -15 * 86_400, :second)

    assert AutoReply.decide(context(%{settings: settings, last_activity_at: idle})) ==
             {:send, :greeting}

    recent = DateTime.add(~U[2026-08-26 10:00:00Z], -3 * 86_400, :second)
    assert AutoReply.decide(context(%{settings: settings, last_activity_at: recent})) == :skip
  end

  test "SCHEDULE: timezone conversion — 22:00-06:00 IST crossing midnight, both sides + off-hours" do
    schedule = %{
      "timezone" => "Asia/Kolkata",
      "ranges" => [%{"days" => [1, 2, 3, 4, 5], "start" => "22:00", "end" => "06:00"}]
    }

    custom = away(%{"mode" => "custom", "schedule" => schedule})

    # Wednesday 2026-08-26 18:30 UTC = Thursday 00:00 IST → inside (the tail of Wednesday's range).
    assert AutoReply.away_active?(custom, ~U[2026-08-26 18:30:00Z])
    # Wednesday 17:00 UTC = 22:30 IST → inside (the head).
    assert AutoReply.away_active?(custom, ~U[2026-08-26 17:00:00Z])
    # Wednesday 10:00 UTC = 15:30 IST → outside.
    refute AutoReply.away_active?(custom, ~U[2026-08-26 10:00:00Z])
    # Saturday 23:00 IST (Sat=6, not scheduled) → outside even though the TIME matches.
    refute AutoReply.away_active?(custom, ~U[2026-08-29 17:30:00Z])
    # Saturday 01:00 IST — the tail of FRIDAY's (day 5) range → inside.
    assert AutoReply.away_active?(custom, ~U[2026-08-28 19:30:00Z])
  end

  test "SCHEDULE: a plain daytime range respects day boundaries; invalid tz fails CLOSED" do
    schedule = %{
      "timezone" => "Asia/Kolkata",
      "ranges" => [%{"days" => [7], "start" => "09:00", "end" => "17:00"}]
    }

    custom = away(%{"mode" => "custom", "schedule" => schedule})

    # Sunday 2026-08-30 05:30 UTC = 11:00 IST Sunday (day 7) → inside.
    assert AutoReply.away_active?(custom, ~U[2026-08-30 05:30:00Z])
    # Monday same time → outside.
    refute AutoReply.away_active?(custom, ~U[2026-08-31 05:30:00Z])

    broken =
      away(%{
        "mode" => "custom",
        "schedule" => %{"timezone" => "Not/AZone", "ranges" => schedule["ranges"]}
      })

    refute AutoReply.away_active?(broken, ~U[2026-08-30 05:30:00Z])
  end

  test "claim windows: greeting = resend days; away = 24h" do
    settings = %{away: away(), greeting: greeting(%{"resend_after_days" => 3})}
    assert AutoReply.claim_window_seconds(:greeting, settings) == 3 * 86_400
    assert AutoReply.claim_window_seconds(:away, settings) == 86_400
  end
end
