defmodule AuthService.AccountDeletion do
  @moduledoc """
  SELF-SERVE ACCOUNT DELETION (App Store guideline 5.1.1(v), Play Data safety).

  A user deletes their own account. Everything personal goes; the identity row stays behind as a
  TOMBSTONE so that messages other people already received still render as being from someone.

  ## The tombstone, and why it is not a hard delete

  `AuthService.Moderation.delete_user/1` — the admin path — hard-deletes `users_auth` and reassigns
  the three NOT-NULL blockers to the acting root. A self-delete cannot do that: there IS no other
  actor, and putting a stranger's name on a group the deleted user created is worse than keeping a
  dead row. More importantly, messages in other people's chats carry a `sender_user_id`; orphan it
  and the recipient's client renders a blank rather than "Deleted account". So `users_auth` survives
  with `deleted_at` set, `status = 'deleted'` and its identity columns scrubbed (130).

  `Sessions.active_user/1` admits only `status == "active"`, so the status flip is what ends every
  session already in flight — including ones whose access token has minutes left to run.

  ## The purge is CATALOG-DRIVEN, deliberately

  Thirty-five tables hold a foreign key into `users_auth` with ON DELETE CASCADE, across forty-one
  columns. Hand-listing them here would be wrong within a month: every feature slice adds another,
  and a table missed in this list is personal data that survives a deletion silently. So the list is
  READ FROM THE CATALOG at delete time — whatever currently cascades gets purged, including tables
  that did not exist when this was written.

  Two tables are held back from that sweep and handled by name, because purging them would be wrong:

    * `conversation_participants` — the row is UPDATED (`left_at`), not deleted. Deleting it removes
      the person from the other side's direct chat entirely, and the peer's client resolves the chat
      title from that participant. Setting `left_at` is the existing "no longer a member" marker: it
      removes them from every group, and leaves the DM resolvable so it can say who it was with.
    * `users_auth` itself is not in the catalog result (nothing cascades a table to itself), but the
      three NO-ACTION referents — conversations.created_by, media_assets.owner_user_id,
      call_sessions.started_by — are why the row has to stay at all.

  `AccountDeletionTest` pins the resolved set. A new cascading table makes that test fail rather than
  quietly joining or missing the purge, which is the only way a list like this stays honest.

  ## The re-auth guard

  The caller must present the account's own registered phone number. A valid session is not enough:
  the threat is a handset someone else is already holding, where the session is exactly what the
  attacker has. This is possession-of-knowledge, the same thing the email deletion route asks for.
  An OTP step-up would be stronger and is the obvious upgrade; it needs a two-call flow this does not
  have yet.
  """

  require Logger

  alias AuthService.Repo

  # Purged by name rather than by the catalog sweep — see the moduledoc. Anything listed here MUST be
  # handled explicitly below, or deletion silently leaves it behind.
  @handled_by_name ~w(conversation_participants)

  @doc """
  Delete the caller's own account. `attrs` needs `"user_id"` (from the session, never the body) and
  `"phone_number"` (the re-auth guard).

  Returns `{:ok, %{user_id: id, deleted_at: iso8601, purged: n}}`, or:

    * `:account_not_found`   — no such active account (also the answer for an already-deleted one)
    * `:reauth_failed`       — the phone number does not match this account
    * `:account_undeletable` — a root/admin account; the console owner cannot delete themselves out
                               of their own platform by tapping a button in the app
  """
  def delete_own_account(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, claimed_phone} <- required(attrs, "phone_number"),
         {:ok, user} <- fetch_deletable(user_id),
         :ok <- guard_reauth(user, claimed_phone) do
      Repo.transaction(fn -> purge(user) end)
    end
  rescue
    error in Postgrex.Error ->
      SharedInfra.SqlFault.classify(
        error,
        __STACKTRACE__,
        "AccountDeletion.delete_own_account",
        {:error, :account_delete_failed}
      )
  end

  defp purge(%{id: user_id} = user) do
    now = DateTime.utc_now()

    # 1. LEAVE every conversation. Not a delete: see the moduledoc.
    Repo.query!(
      "UPDATE conversation_participants SET left_at = now() " <>
        "WHERE user_id = $1::text::uuid AND left_at IS NULL",
      [user_id]
    )

    # 2. The username hold, exactly as a rename and an admin delete write it. The profile row is
    #    purged in step 3, which would FREE the handle instantly — the claim-a-name-someone-just-
    #    vacated impersonation vector the hold exists to close.
    Repo.query!(
      "INSERT INTO username_holds (app_id, username_key, user_id, held_until) " <>
        "SELECT p.app_id, p.username_key, p.user_id, now() + interval '30 days' " <>
        "FROM user_profiles p WHERE p.user_id = $1::text::uuid AND p.username_key IS NOT NULL " <>
        "ON CONFLICT (app_id, username_key) DO UPDATE " <>
        "SET user_id = EXCLUDED.user_id, held_until = EXCLUDED.held_until, created_at = now()",
      [user_id]
    )

    # 3. THE CATALOG SWEEP. Every column that currently cascades off users_auth, minus the ones
    #    handled by name above. Reading it here rather than listing it is what keeps a table added
    #    next month from silently surviving a deletion.
    purged = Enum.map(cascade_columns(), &purge_column(&1, user_id))

    # 4. The tombstone. Identity scrubbed: a NULL phone frees the number for re-registration
    #    immediately (the unique index is PARTIAL on phone_number IS NOT NULL), and the relaxed
    #    identity check (130) is what allows all three identity columns to be empty at once.
    Repo.query!(
      "UPDATE users_auth SET status = 'deleted', deleted_at = $2, phone_number = NULL, " <>
        "email = NULL, password_hash = NULL, external_id = NULL, updated_at = now() " <>
        "WHERE id = $1::text::uuid",
      [user_id, now]
    )

    total = Enum.sum(Enum.map(purged, fn {_table, _column, rows} -> rows end))

    Logger.info(
      "account deleted user=#{user_id} tables=#{length(purged)} rows=#{total} " <>
        "role=#{user.role} self_serve=true"
    )

    %{user_id: user_id, deleted_at: DateTime.to_iso8601(now), purged: total}
  end

  defp purge_column({table, column}, user_id) do
    %Postgrex.Result{num_rows: rows} =
      Repo.query!(
        "DELETE FROM #{quoted(table)} WHERE #{quoted(column)} = $1::text::uuid",
        [user_id]
      )

    {table, column, rows}
  end

  @doc """
  Every `{table, column}` that references `users_auth` with ON DELETE CASCADE, minus the ones this
  module handles by name. Read from `pg_constraint` so it cannot drift from the schema.

  PUBLIC so the test can pin the resolved set: the guard against a new cascading table is the
  difference between a deletion that is complete and one that only looks complete.
  """
  def cascade_columns do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        """
        SELECT c.conrelid::regclass::text, a.attname
        FROM pg_constraint c
        JOIN unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord) ON true
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
        WHERE c.contype = 'f'
          AND c.confrelid = 'users_auth'::regclass
          AND c.confdeltype = 'c'
        ORDER BY 1, 2
        """,
        []
      )

    rows
    |> Enum.map(fn [table, column] -> {table, column} end)
    |> Enum.reject(fn {table, _column} -> table in @handled_by_name end)
  end

  @doc "The tables this module purges by name instead of through the catalog sweep."
  def handled_by_name, do: @handled_by_name

  # An identifier out of the catalog is already trustworthy, but it is being interpolated into SQL —
  # quote it so a table named with anything unusual cannot change the statement's shape.
  defp quoted(identifier), do: ~s("#{String.replace(identifier, ~s("), ~s(""))}")

  defp fetch_deletable(user_id) do
    case Repo.query(
           "SELECT id::text, phone_number, role FROM users_auth WHERE id = $1::text::uuid AND status = 'active'",
           [user_id]
         ) do
      {:ok, %{rows: [[id, phone, role]]}} ->
        if role in ["root", "admin"] do
          {:error, :account_undeletable}
        else
          {:ok, %{id: id, phone_number: phone, role: role}}
        end

      _ ->
        {:error, :account_not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :account_not_found}
    Postgrex.Error -> {:error, :account_not_found}
  end

  # Constant-time-ish compare on a value that is not a secret, but the comparison still should not
  # leak length by short-circuiting differently for a near-miss.
  defp guard_reauth(%{phone_number: stored}, claimed)
       when is_binary(stored) and is_binary(claimed) do
    if :crypto.hash_equals(normalise(stored), normalise(claimed)),
      do: :ok,
      else: {:error, :reauth_failed}
  end

  defp guard_reauth(_user, _claimed), do: {:error, :reauth_failed}

  # The stored number is E.164; a client may send it with spaces or a leading 00. Normalising is not
  # leniency — it is refusing to fail a legitimate deletion over formatting the user cannot see.
  defp normalise(value) do
    digits = String.replace(value, ~r/[^0-9]/, "")
    :crypto.hash(:sha256, digits)
  end

  defp required(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, String.to_existing_atom(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :account_delete_invalid}
    end
  rescue
    ArgumentError -> {:error, :account_delete_invalid}
  end
end
