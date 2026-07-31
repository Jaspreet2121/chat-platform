defmodule UserService.Usernames do
  @moduledoc """
  Usernames (080) — the optional, per-tenant @handle. Validation, set/change/remove, lookup,
  availability.

  FORMAT: `^[A-Za-z][A-Za-z0-9_]{2,29}$` (3–30, ASCII only). NORMALISATION, exactly:
  `username_key = String.downcase(username)` — lowercase IS the whole rule because the alphabet is
  pure ASCII (NFKC deliberately a no-op; anything needing it is rejected). Case-preserving display,
  case-insensitive uniqueness/lookup. Homographs are impossible BY CONSTRUCTION (no Unicode accepted);
  visually-similar ASCII (0/O, 1/l) is deliberately NOT defended.

  CHANGE POLICY: 2 changes per rolling 30 days; a vacated handle is HELD 30 days (rename, removal, and
  account deletion all vacate). The budget is COUNTED FROM the holds rows (created_at in window), and
  holds are never deleted by user action — so @a → @b → @a costs two changes and refunds nothing
  (reclaim writes hold(@b); hold(@a) stays). The vacating owner may reclaim inside the window; anyone
  else → :username_held. CASE-ONLY edits (@Alice → @alice: same key) are FREE — display-only update,
  no hold, no budget, no collision with yourself.

  LOOKUP resolves ACTIVE accounts only (users_auth.status = 'active' — by-phone parity) and is always
  app-scoped: there is no app-blind variant. Suspended/deleted accounts keep their handle blocked
  (suspension is soft — the row stays; hard deletion writes a 30-day hold in the delete transaction).
  """

  import Ecto.Query

  alias UserService.ProfileStore
  alias UserService.Repo
  alias UserService.Schemas.UserProfile

  @format ~r/^[A-Za-z][A-Za-z0-9_]{2,29}$/
  @min_length 3
  @max_length 30
  @max_changes 2
  @window_days 30
  @hold_days 30

  # Impersonation-bait handles, checked against the NORMALISED key (so AdMin is caught). Config (code)
  # over a table: small, code-reviewed, ships with deploys. Per-tenant brand terms are the natural
  # extension when integrator branding exists (a reserved_usernames table keyed by app_id) — not built.
  @reserved ~w(admin administrator support help helpdesk root system sys mod moderator security
               official staff team info contact abuse api www app web growblic exway)

  def max_changes, do: @max_changes
  def hold_days, do: @hold_days

  @doc "Validate a candidate handle. :ok | {:error, :username_too_short | :username_too_long | :username_invalid_format | :username_reserved}"
  def validate(username) when is_binary(username) do
    cond do
      String.length(username) < @min_length -> {:error, :username_too_short}
      String.length(username) > @max_length -> {:error, :username_too_long}
      not Regex.match?(@format, username) -> {:error, :username_invalid_format}
      String.downcase(username) in @reserved -> {:error, :username_reserved}
      true -> :ok
    end
  end

  def validate(_username), do: {:error, :username_invalid_format}

  @doc """
  Set / change / remove ("" or nil-explicit removal is the caller's contract: "" removes) the caller's
  username. Returns {:ok, %{username, username_key}} (both nil after removal).
  Errors: validation codes, :username_taken, :username_held, :username_change_limit, :profile_not_found.
  """
  def set_username(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         %UserProfile{} = profile <-
           ProfileStore.get_profile(user_id) || {:error, :profile_not_found} do
      case Map.get(attrs, "username") do
        "" -> remove_username(profile)
        username when is_binary(username) -> apply_username(profile, username)
        _ -> {:error, :username_invalid_format}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.Query.CastError -> {:error, :profile_invalid}
  end

  @doc "Resolve a handle (any casing) → {:ok, %{user_id}} for an ACTIVE account in `app_id`, else :not_found."
  def lookup(attrs) do
    with {:ok, username} <- required(attrs, "username"),
         {:ok, app_id} <- required(attrs, "app_id") do
      key = String.downcase(username)

      result =
        Repo.query!(
          # ACTIVE-only — the same status filter the phone lookups apply (by-phone parity): a
          # suspended/deleted account's handle stays BLOCKED (the row/hold persists) but resolves nothing.
          "SELECT p.user_id::text FROM user_profiles p JOIN users_auth u ON u.id = p.user_id " <>
            "WHERE p.app_id = $1::text::uuid AND p.username_key = $2 AND u.status = 'active'",
          [app_id, key]
        )

      case result.rows do
        [[user_id]] -> {:ok, %{user_id: user_id}}
        _ -> {:error, :not_found}
      end
    end
  rescue
    _ -> {:error, :not_found}
  end

  @doc """
  Availability of a handle in `app_id` for `user_id` (their own current handle reports available —
  a case-only edit is not a collision). Invalid/reserved handles carry their validation code so the
  client can render the exact failure. → {:ok, %{available: bool, code: nil | binary}}
  """
  def check_availability(attrs) do
    with {:ok, username} <- required(attrs, "username"),
         {:ok, app_id} <- required(attrs, "app_id"),
         {:ok, user_id} <- required(attrs, "user_id") do
      case validate(username) do
        {:error, code} ->
          {:ok, %{available: false, code: to_string(code)}}

        :ok ->
          key = String.downcase(username)

          taken? =
            UserProfile
            |> where(
              [p],
              p.app_id == ^app_id and p.username_key == ^key and p.user_id != ^user_id
            )
            |> Repo.exists?()

          held? = held_by_other?(app_id, key, user_id)

          cond do
            taken? -> {:ok, %{available: false, code: "username_taken"}}
            held? -> {:ok, %{available: false, code: "username_held"}}
            true -> {:ok, %{available: true, code: nil}}
          end
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :profile_invalid}
  end

  @doc """
  Write the 30-day hold for a vacated handle (rename/removal — and the ADMIN DELETE transaction calls
  the SQL twin of this so a hard-deleted account's handle can't be claimed instantly). Upsert on
  (app_id, username_key): re-vacating renews the row.
  """
  def write_hold(app_id, username_key, user_id) do
    Repo.query!(
      "INSERT INTO username_holds (app_id, username_key, user_id, held_until) " <>
        "VALUES ($1::text::uuid, $2, $3::text::uuid, now() + make_interval(days => $4)) " <>
        "ON CONFLICT (app_id, username_key) DO UPDATE " <>
        "SET user_id = EXCLUDED.user_id, held_until = EXCLUDED.held_until, created_at = now()",
      [app_id, username_key, user_id, @hold_days]
    )

    :ok
  end

  # --- internals ---------------------------------------------------------------------------------

  defp apply_username(profile, username) do
    key = String.downcase(username)

    cond do
      # CASE-ONLY edit: same key → display-only update. No hold, no budget, no self-collision.
      profile.username_key == key and profile.username != username ->
        update_handle(profile, username, key, hold: false)

      profile.username_key == key ->
        # Identical to the current handle — a no-op that costs nothing.
        {:ok, %{username: profile.username, username_key: key}}

      true ->
        with :ok <- validate(username),
             :ok <- ensure_not_held(profile, key),
             :ok <- ensure_budget(profile) do
          update_handle(profile, username, key, hold: profile.username_key != nil)
        end
    end
  end

  defp remove_username(%UserProfile{username_key: nil}),
    do: {:ok, %{username: nil, username_key: nil}}

  defp remove_username(profile) do
    with :ok <- ensure_budget(profile) do
      update_handle(profile, nil, nil, hold: true)
    end
  end

  # The transactional write: vacate (hold) + claim, atomically. The unique index is the truth for
  # collisions — a race between two claimants surfaces as :username_taken, never a double-claim.
  defp update_handle(profile, username, key, hold: hold?) do
    Repo.transaction(fn ->
      # Removal ("" ) and rename both vacate the OLD handle; the hold makes release non-instant
      # (and the row is what the change budget counts — never deleted by user action).
      if hold? and profile.username_key != nil do
        write_hold(profile.app_id, profile.username_key, profile.user_id)
      end

      result =
        Repo.query(
          "UPDATE user_profiles SET username = $2, username_key = $3, updated_at = now() " <>
            "WHERE user_id = $1::text::uuid",
          [profile.user_id, username, key]
        )

      case result do
        {:ok, %Postgrex.Result{num_rows: 1}} ->
          %{username: username, username_key: key}

        {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} ->
          Repo.rollback(:username_taken)

        _ ->
          Repo.rollback(:profile_invalid)
      end
    end)
  end

  # A live hold by SOMEONE ELSE blocks the claim; the vacating owner may reclaim (undo-a-mistake).
  defp ensure_not_held(profile, key) do
    if held_by_other?(profile.app_id, key, profile.user_id) do
      {:error, :username_held}
    else
      :ok
    end
  end

  defp held_by_other?(app_id, key, user_id) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM username_holds WHERE app_id = $1::text::uuid AND username_key = $2 " <>
          "AND user_id <> $3::text::uuid AND held_until > now()",
        [app_id, key, user_id]
      )

    rows != []
  end

  # 2 changes per rolling 30 days, counted from MY holds (each change/removal writes exactly one; the
  # FIRST set is free — no previous handle, no hold). Reclaim can't refund: holds are never deleted.
  defp ensure_budget(profile) do
    %Postgrex.Result{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*)::int FROM username_holds WHERE user_id = $1::text::uuid " <>
          "AND created_at > now() - make_interval(days => $2)",
        [profile.user_id, @window_days]
      )

    if count >= @max_changes, do: {:error, :username_change_limit}, else: :ok
  end

  defp required(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, String.to_atom(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :profile_invalid}
    end
  end
end
