defmodule RealtimeGateway.AutoReply do
  @moduledoc """
  Auto-reply DECISION CORE (102) — pure: `decide(context)` looks at one inbound 1:1 message and the
  recipient's settings and returns `:skip` or `{:send, :greeting | :away}`. All I/O (event decode,
  lookups, the claim, the send) lives in `RealtimeGateway.AutoReplyConsumer`; this module is where
  the product rules are, so the whole matrix is unit-testable without any infrastructure.

  Hard skips, in order: not a message.created event; group conversation; sender == recipient; the
  inbound message itself is automated (metadata `auto` — LOOP-PROOF: our own replies always carry
  it, so an auto-reply can never trigger an auto-reply); either side blocks the other; both features
  disabled. When both greeting and away are due → GREETING ONLY (the warmer message wins; the away
  throttle is untouched so away can still fire on the NEXT inbound).

  Audience: `contacts` = the sender is in the recipient's FAVOURITE contacts — the only persisted
  contact relation (contacts sync is deliberately stateless); recorded as an approximation until
  contact-sync persistence exists. `except` = everyone minus except_ids.
  """

  @type context :: %{
          required(:conversation_type) => String.t() | nil,
          required(:sender_id) => String.t() | nil,
          required(:recipient_id) => String.t() | nil,
          required(:sender_auto?) => boolean(),
          required(:blocked?) => boolean(),
          required(:settings) => %{away: map(), greeting: map()},
          required(:contact?) => boolean(),
          # Last conversation activity BEFORE the triggering message; nil = first message ever.
          required(:last_activity_at) => DateTime.t() | nil,
          required(:now) => DateTime.t()
        }

  @spec decide(context()) :: :skip | {:send, :greeting} | {:send, :away}
  def decide(context) do
    away = context.settings.away
    greeting = context.settings.greeting

    cond do
      context.conversation_type != "direct" -> :skip
      is_nil(context.sender_id) or is_nil(context.recipient_id) -> :skip
      context.sender_id == context.recipient_id -> :skip
      context.sender_auto? -> :skip
      context.blocked? -> :skip
      not (enabled?(away) or enabled?(greeting)) -> :skip
      greeting_due?(greeting, context) -> {:send, :greeting}
      away_due?(away, context) -> {:send, :away}
      true -> :skip
    end
  end

  @doc "The claim window for a kind, from the recipient's settings (greeting: resend days; away: 24 h)."
  def claim_window_seconds(:greeting, settings),
    do: (Map.get(settings.greeting, "resend_after_days") || 14) * 86_400

  def claim_window_seconds(:away, _settings), do: 86_400

  defp greeting_due?(greeting, context) do
    enabled?(greeting) and
      audience_match?(greeting, context) and
      idle_or_first?(context, Map.get(greeting, "resend_after_days") || 14)
  end

  defp away_due?(away, context) do
    enabled?(away) and audience_match?(away, context) and away_active?(away, context.now)
  end

  # First message ever (nil) OR the conversation slept longer than the resend window before this
  # message. The 24 h/N-day per-conversation LOG throttle is enforced separately at claim time —
  # this is the product condition, that is the at-least-once dedupe.
  defp idle_or_first?(%{last_activity_at: nil}, _days), do: true

  defp idle_or_first?(%{last_activity_at: last, now: now}, days),
    do: DateTime.diff(now, last, :second) > days * 86_400

  @doc """
  Is away active at `now`? mode "always" → yes. mode "custom" → `now` shifted into the schedule's
  timezone falls inside ANY range. A range whose start > end crosses midnight: it matches its day
  from `start` to 24:00 AND the FOLLOWING day from 00:00 to `end`.
  """
  def away_active?(away, now) do
    case Map.get(away, "mode", "always") do
      "always" ->
        true

      "custom" ->
        schedule = Map.get(away, "schedule") || %{}
        timezone = Map.get(schedule, "timezone") || "Etc/UTC"

        case DateTime.shift_zone(now, timezone) do
          {:ok, local} ->
            ranges = Map.get(schedule, "ranges") || []
            Enum.any?(ranges, &range_active?(&1, local))

          # An invalid zone should have been rejected at write; fail CLOSED (no reply) rather than
          # replying at the wrong hours.
          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp range_active?(%{"days" => days, "start" => start_hm, "end" => end_hm}, local) do
    minutes = local.hour * 60 + local.minute
    start_min = to_minutes(start_hm)
    end_min = to_minutes(end_hm)
    today = Date.day_of_week(DateTime.to_date(local))
    yesterday = today |> Kernel.-(2) |> Integer.mod(7) |> Kernel.+(1)

    cond do
      is_nil(start_min) or is_nil(end_min) ->
        false

      start_min <= end_min ->
        today in days and minutes >= start_min and minutes < end_min

      # Crosses midnight: tonight's tail belongs to a range STARTING today; this morning's head
      # belongs to a range that started YESTERDAY.
      true ->
        (today in days and minutes >= start_min) or
          (yesterday in days and minutes < end_min)
    end
  end

  defp range_active?(_range, _local), do: false

  defp to_minutes(<<h1, h2, ?:, m1, m2>>) do
    with {hours, ""} <- Integer.parse(<<h1, h2>>),
         {minutes, ""} <- Integer.parse(<<m1, m2>>) do
      hours * 60 + minutes
    else
      _ -> nil
    end
  end

  defp to_minutes(_), do: nil

  defp audience_match?(block, context) do
    case Map.get(block, "audience", "everyone") do
      "everyone" -> true
      "contacts" -> context.contact?
      "non_contacts" -> not context.contact?
      "except" -> context.sender_id not in (Map.get(block, "except_ids") || [])
      _ -> false
    end
  end

  defp enabled?(block), do: Map.get(block, "enabled") == true
end
