defmodule UserService.AutoReplies do
  @moduledoc """
  Auto-reply settings + dedupe ledger (102). Settings are per-user jsonb blocks (`away`, `greeting`),
  BOTH DISABLED by default — an absent row is the OFF state, so the feature is invisible until a user
  turns it on. Validation is strict at write time so the async engine can trust what it reads.

  `claim/1` is the at-least-once safety: the engine claims BEFORE sending (a missed reply self-heals
  next window; a duplicate reply is user-visible noise). Rolling windows (24 h away, N-day greeting)
  cannot be a unique index, so the check+insert runs under `pg_advisory_xact_lock` keyed on
  (user, conversation, kind) — the lock serializes exactly the contending pair, holds only for the
  transaction, and leaves no table bloat behind.
  """

  alias UserService.Repo

  @audiences ~w(everyone contacts non_contacts except)
  @away_modes ~w(always custom)
  @body_max 500
  @except_max 100
  @default_resend_days 14

  @doc "The caller's settings with defaults applied (absent row/keys = disabled)."
  def get_settings(attrs) do
    with :ok <- persistence(), {:ok, user_id} <- required(attrs, "user_id") do
      %{rows: rows} =
        Repo.query!(
          "SELECT away, greeting FROM auto_reply_settings WHERE user_id = $1::text::uuid",
          [user_id]
        )

      {away, greeting} =
        case rows do
          [[away, greeting]] -> {decode_json(away), decode_json(greeting)}
          [] -> {%{}, %{}}
        end

      {:ok, %{away: away_with_defaults(away), greeting: greeting_with_defaults(greeting)}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :auto_reply_invalid}
  end

  @doc """
  PATCH semantics: each provided block replaces that block wholesale after validation (a partial
  block would leave the engine guessing); the other block is untouched.
  """
  def update_settings(attrs) do
    with :ok <- persistence(),
         {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, app_id} <- required(attrs, "app_id"),
         {:ok, away} <- validate_away(Map.get(attrs, "away")),
         {:ok, greeting} <- validate_greeting(Map.get(attrs, "greeting")) do
      away_json = if away, do: Jason.encode!(away), else: nil
      greeting_json = if greeting, do: Jason.encode!(greeting), else: nil

      Repo.query!(
        """
        INSERT INTO auto_reply_settings (user_id, app_id, away, greeting, updated_at)
        VALUES ($1::text::uuid, $2::text::uuid,
                COALESCE($3::jsonb, '{}'::jsonb), COALESCE($4::jsonb, '{}'::jsonb), now())
        ON CONFLICT (user_id) DO UPDATE SET
          app_id = EXCLUDED.app_id,
          away = COALESCE($3::jsonb, auto_reply_settings.away),
          greeting = COALESCE($4::jsonb, auto_reply_settings.greeting),
          updated_at = now()
        """,
        [user_id, app_id, away_json, greeting_json]
      )

      get_settings(%{"user_id" => user_id})
    end
  rescue
    Ecto.Query.CastError -> {:error, :auto_reply_invalid}
  end

  @doc """
  Engine claim (at-least-once safe): under an advisory xact lock, insert a log row UNLESS one exists
  for (user, conversation, kind) within `window_seconds`. → {:ok, :claimed} | {:ok, :throttled}.
  """
  def claim(attrs) do
    with :ok <- persistence(),
         {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, app_id} <- required(attrs, "app_id"),
         {:ok, conversation_id} <- required(attrs, "conversation_id"),
         {:ok, kind} <- kind(attrs),
         {:ok, window} <- window(attrs) do
      {:ok, outcome} =
        Repo.transaction(fn ->
          Repo.query!(
            "SELECT pg_advisory_xact_lock(hashtextextended($1 || ':' || $2 || ':' || $3, 0))",
            [user_id, conversation_id, kind]
          )

          %{rows: [[exists]]} =
            Repo.query!(
              """
              SELECT EXISTS (
                SELECT 1 FROM auto_reply_log
                WHERE user_id = $1::text::uuid AND conversation_id = $2::text::uuid
                  AND kind = $3 AND sent_at > now() - make_interval(secs => $4)
              )
              """,
              [user_id, conversation_id, kind, window]
            )

          if exists do
            :throttled
          else
            Repo.query!(
              "INSERT INTO auto_reply_log (app_id, user_id, conversation_id, kind) " <>
                "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, $4)",
              [app_id, user_id, conversation_id, kind]
            )

            :claimed
          end
        end)

      {:ok, outcome}
    end
  rescue
    Ecto.Query.CastError -> {:error, :auto_reply_invalid}
  end

  # jsonb comes back as a map through Ecto types but as a STRING through some raw-query paths —
  # accept both (the engine reads through this too; guessing wrong is a silent all-off).
  defp decode_json(value) when is_map(value), do: value

  defp decode_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_json(_), do: %{}

  # --- defaults ----------------------------------------------------------------------------------

  def away_with_defaults(stored) do
    Map.merge(
      %{
        "enabled" => false,
        "mode" => "always",
        "schedule" => nil,
        "audience" => "everyone",
        "except_ids" => [],
        "body" => nil
      },
      stored || %{}
    )
  end

  def greeting_with_defaults(stored) do
    Map.merge(
      %{
        "enabled" => false,
        "audience" => "everyone",
        "body" => nil,
        "resend_after_days" => @default_resend_days
      },
      stored || %{}
    )
  end

  # --- validation --------------------------------------------------------------------------------

  defp validate_away(nil), do: {:ok, nil}

  defp validate_away(%{} = away) do
    enabled = Map.get(away, "enabled") == true
    mode = Map.get(away, "mode", "always")

    cond do
      # The recorded follow-up: business-hours mode needs STRUCTURED business hours first.
      mode == "outside_business_hours" ->
        {:error, :auto_reply_unsupported_mode}

      mode not in @away_modes ->
        {:error, :auto_reply_invalid}

      enabled and not valid_body?(Map.get(away, "body")) ->
        {:error, :auto_reply_body_required}

      true ->
        with {:ok, schedule} <- validate_schedule(mode, Map.get(away, "schedule")),
             {:ok, audience} <- validate_audience(away) do
          {:ok,
           %{
             "enabled" => enabled,
             "mode" => mode,
             "schedule" => schedule,
             "audience" => audience,
             "except_ids" => Map.get(away, "except_ids") || [],
             "body" => truncate_body(Map.get(away, "body"))
           }}
        end
    end
  end

  defp validate_away(_), do: {:error, :auto_reply_invalid}

  defp validate_greeting(nil), do: {:ok, nil}

  defp validate_greeting(%{} = greeting) do
    enabled = Map.get(greeting, "enabled") == true
    resend = Map.get(greeting, "resend_after_days", @default_resend_days)

    cond do
      enabled and not valid_body?(Map.get(greeting, "body")) ->
        {:error, :auto_reply_body_required}

      not (is_integer(resend) and resend >= 1 and resend <= 365) ->
        {:error, :auto_reply_invalid}

      true ->
        with {:ok, audience} <- validate_audience(greeting) do
          {:ok,
           %{
             "enabled" => enabled,
             "audience" => audience,
             "except_ids" => Map.get(greeting, "except_ids") || [],
             "body" => truncate_body(Map.get(greeting, "body")),
             "resend_after_days" => resend
           }}
        end
    end
  end

  defp validate_greeting(_), do: {:error, :auto_reply_invalid}

  defp validate_audience(block) do
    audience = Map.get(block, "audience", "everyone")
    except_ids = Map.get(block, "except_ids") || []

    cond do
      audience not in @audiences -> {:error, :auto_reply_invalid}
      not is_list(except_ids) -> {:error, :auto_reply_invalid}
      length(except_ids) > @except_max -> {:error, :auto_reply_too_many_exceptions}
      not Enum.all?(except_ids, &valid_uuid?/1) -> {:error, :auto_reply_invalid}
      true -> {:ok, audience}
    end
  end

  # mode "always" needs no schedule (and drops any provided one — the engine must not read a stale
  # schedule for an always-on away); mode "custom" REQUIRES a valid one.
  defp validate_schedule("always", _schedule), do: {:ok, nil}

  defp validate_schedule("custom", %{"timezone" => timezone, "ranges" => ranges})
       when is_binary(timezone) and is_list(ranges) and ranges != [] do
    with true <- valid_timezone?(timezone),
         true <- Enum.all?(ranges, &valid_range?/1) do
      {:ok, %{"timezone" => timezone, "ranges" => ranges}}
    else
      false -> {:error, :auto_reply_invalid_schedule}
    end
  end

  defp validate_schedule("custom", _), do: {:error, :auto_reply_invalid_schedule}

  defp valid_timezone?(timezone) do
    match?({:ok, _}, DateTime.now(timezone))
  end

  # {"days": [1..7 ISO], "start": "HH:MM", "end": "HH:MM"} — start > end means the range crosses
  # midnight (evaluated by the engine, allowed here).
  defp valid_range?(%{"days" => days, "start" => start_hm, "end" => end_hm})
       when is_list(days) and days != [] do
    Enum.all?(days, &(is_integer(&1) and &1 in 1..7)) and
      valid_hm?(start_hm) and valid_hm?(end_hm)
  end

  defp valid_range?(_), do: false

  defp valid_hm?(<<h1, h2, ?:, m1, m2>>) do
    with {hours, ""} <- Integer.parse(<<h1, h2>>),
         {minutes, ""} <- Integer.parse(<<m1, m2>>) do
      hours in 0..23 and minutes in 0..59
    else
      _ -> false
    end
  end

  defp valid_hm?(_), do: false

  defp valid_body?(body), do: is_binary(body) and String.trim(body) != ""
  defp truncate_body(body) when is_binary(body), do: String.slice(body, 0, @body_max)
  defp truncate_body(_), do: nil

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_uuid?(_), do: false

  defp kind(attrs) do
    case Map.get(attrs, "kind") do
      kind when kind in ["away", "greeting"] -> {:ok, kind}
      _ -> {:error, :auto_reply_invalid}
    end
  end

  defp window(attrs) do
    case Map.get(attrs, "window_seconds") do
      seconds when is_integer(seconds) and seconds > 0 -> {:ok, seconds}
      _ -> {:error, :auto_reply_invalid}
    end
  end

  defp required(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :auto_reply_invalid}
    end
  end

  defp persistence do
    if Application.get_env(:user_service, :user_profile_persistence, false) ||
         System.get_env("USER_PROFILE_DB_BACKED") in ["true", "1", "yes"] do
      :ok
    else
      {:error, :auto_reply_unavailable}
    end
  end
end
