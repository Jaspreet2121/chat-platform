defmodule MessageService.DmStreaks do
  @moduledoc """
  SERVER-AUTHORITATIVE DM streaks (125): consecutive local-calendar days on which BOTH sides of a
  direct conversation sent at least one message. A gap resets the count to 1 at the next such day.

  ## Why this is not a client concern

  Android computed this locally and each device counted from its own history — the same DM read 4 on
  one handset and 6 on another. A streak is a fact about a PAIR of people, not about one device's
  copy of the thread, so it is maintained once here and read by every device.

  ## The day boundary

  A day is the SENDER's local calendar day. The client may send `tz_offset_minutes` (minutes EAST of
  UTC, the sign JavaScript's `-getTimezoneOffset()` produces); when it does not, UTC is used. That
  choice is deliberate and one-sided on purpose: the alternative — picking a day boundary from the
  server's own clock, or from the RECIPIENT's zone — would make the same message count for different
  days depending on who asked. Each send is attributed to the day it was sent in, where it was sent.
  Documented in docs/05-api-contracts/conversation-service.md; each decision path logs once.

  ## How "both sides" is known without reading `messages`

  `conversation_participants.last_message_on` records the date each member last sent in that
  conversation. Under the Scylla store the Postgres `messages` table is FROZEN and effectively
  empty, so a query over it would answer "the other side never messaged" forever. The participant
  column is maintained on the write that would have been scanned for.

  ## Fail-soft

  Every outcome is `:ok`. A streak is a decoration on a conversation; a message that failed to send
  because its streak bookkeeping raised would be a real outage caused by a cosmetic feature.
  """

  require Logger

  alias MessageService.Repo

  @doc """
  Maintain the streak for one just-committed message. DIRECT conversations only — a group never gets
  a row (there is no "both sides" in a group). Called after the store write, never before it.
  """
  def record_message(attrs) do
    conversation_id = get(attrs, "conversation_id")
    sender_user_id = get(attrs, "sender_user_id")

    with true <- is_binary(conversation_id) and is_binary(sender_user_id),
         {:ok, :direct} <- conversation_kind(conversation_id) do
      today = local_today(attrs, conversation_id)
      maintain(conversation_id, sender_user_id, today)
    else
      _ -> :ok
    end
  rescue
    error ->
      # The message is already committed and is the user-visible outcome.
      Logger.warning(
        "dm streak skipped conversation=#{get(attrs, "conversation_id")} reason=#{inspect(error)}"
      )

      :ok
  end

  # NOTE on the parameters below: a `$N::date` placeholder must be given a `%Date{}` — Postgrex reads
  # the cast annotation and REFUSES an ISO string ("expected %Date{}, got …"), which the fail-soft
  # rescue would then swallow as a skipped streak. Dates go in as structs, never as text.
  defp maintain(conversation_id, sender_user_id, today) do
    # The sender's own mark first: "I sent today". Idempotent — a second message the same day writes
    # the same date.
    Repo.query!(
      "UPDATE conversation_participants SET last_message_on = $3::date " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid AND left_at IS NULL " <>
        "AND (last_message_on IS DISTINCT FROM $3::date)",
      [conversation_id, sender_user_id, today]
    )

    cond do
      already_counted?(conversation_id, today) ->
        Logger.info("dm streak skipped conversation=#{conversation_id} reason=same_day")

        :ok

      not both_sides_today?(conversation_id, sender_user_id, today) ->
        Logger.info("dm streak skipped conversation=#{conversation_id} reason=not_both_sides")

        :ok

      true ->
        count = advance(conversation_id, today)
        Logger.info("dm streak updated conversation=#{conversation_id} days=#{count}")
        :ok
    end
  end

  # Today is already counted → nothing to do. This is what stops the second message of a day (from
  # either side) incrementing again.
  defp already_counted?(conversation_id, today) do
    case Repo.query!(
           "SELECT last_both_sides_date FROM dm_streaks WHERE conversation_id = $1::text::uuid",
           [conversation_id]
         ) do
      %{rows: [[%Date{} = counted]]} -> Date.compare(counted, today) == :eq
      _ -> false
    end
  end

  # Every OTHER active member must have sent today. For a direct conversation that is exactly one
  # person; written as "no active member is missing" so it cannot silently pass on a malformed row.
  defp both_sides_today?(conversation_id, sender_user_id, today) do
    %{rows: rows} =
      Repo.query!(
        "SELECT count(*)::int FROM conversation_participants " <>
          "WHERE conversation_id = $1::text::uuid AND user_id <> $2::text::uuid " <>
          "AND left_at IS NULL AND (last_message_on IS NULL OR last_message_on <> $3::date)",
        [conversation_id, sender_user_id, today]
      )

    case rows do
      [[0]] -> true
      _ -> false
    end
  end

  # Consecutive day → +1; any gap (or a first count) → 1. ONE statement, so two concurrent sends
  # cannot both read the old value and both write N+1.
  defp advance(conversation_id, today) do
    %{rows: [[days]]} =
      Repo.query!(
        "INSERT INTO dm_streaks (conversation_id, streak_days, last_both_sides_date, updated_at) " <>
          "VALUES ($1::text::uuid, 1, $2::date, now()) " <>
          "ON CONFLICT (conversation_id) DO UPDATE SET " <>
          "  streak_days = CASE " <>
          "    WHEN dm_streaks.last_both_sides_date = $2::date - 1 THEN dm_streaks.streak_days + 1 " <>
          "    ELSE 1 END, " <>
          "  last_both_sides_date = $2::date, " <>
          "  updated_at = now() " <>
          "WHERE dm_streaks.last_both_sides_date IS DISTINCT FROM $2::date " <>
          "RETURNING streak_days",
        [conversation_id, today]
      )

    days
  end

  @doc "The conversation's type, or :error when it cannot be read. Public for the tests."
  def conversation_kind(conversation_id) do
    case Repo.query!(
           "SELECT type FROM conversations WHERE id = $1::text::uuid",
           [conversation_id]
         ) do
      %{rows: [["direct"]]} -> {:ok, :direct}
      %{rows: [[other]]} -> {:ok, other}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  The sender's local calendar day: their `tz_offset_minutes` when the client sent one, else UTC.
  Logged ONCE per decision path per conversation so a support question ("why did my streak roll at
  7pm?") is answerable from the log alone.
  """
  def local_today(attrs, conversation_id \\ nil) do
    now = DateTime.utc_now()

    case tz_offset_minutes(attrs) do
      nil ->
        log_once({:tz, conversation_id, :utc}, fn ->
          Logger.info("dm streak day=utc conversation=#{conversation_id} reason=no_client_offset")
        end)

        DateTime.to_date(now)

      minutes ->
        log_once({:tz, conversation_id, minutes}, fn ->
          Logger.info(
            "dm streak day=client_offset conversation=#{conversation_id} offset_minutes=#{minutes}"
          )
        end)

        now |> DateTime.add(minutes * 60, :second) |> DateTime.to_date()
    end
  end

  # ±14h is the real range of civil offsets (UTC-12 … UTC+14); anything outside is a broken client,
  # and honouring it would let a caller pick which day their message lands in.
  @max_offset_minutes 14 * 60

  defp tz_offset_minutes(attrs) do
    case get(attrs, "tz_offset_minutes") do
      value
      when is_integer(value) and value >= -@max_offset_minutes and value <= @max_offset_minutes ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed >= -@max_offset_minutes and parsed <= @max_offset_minutes ->
            parsed

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  # "Once per decision path": the process dictionary, so a burst of sends logs the choice once and a
  # later send in a different zone still says so. Not a cache of the DECISION — only of the LOG.
  defp log_once(key, fun) do
    if Process.get({__MODULE__, key}) do
      :ok
    else
      Process.put({__MODULE__, key}, true)
      fun.()
      :ok
    end
  end

  defp get(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, safe_atom(key))

  defp get(_attrs, _key), do: nil

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
