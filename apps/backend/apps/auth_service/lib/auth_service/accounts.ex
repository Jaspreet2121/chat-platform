defmodule AuthService.Accounts do
  @moduledoc """
  Data-access boundary for auth identities in `users_auth`.
  """

  import Ecto.Query, only: [from: 2]

  alias AuthService.Repo
  alias AuthService.Schemas.UserAuth

  def user_changeset(attrs \\ %{}) do
    UserAuth.changeset(%UserAuth{}, attrs)
  end

  def create_user(attrs) do
    attrs
    |> user_changeset()
    |> Repo.insert()
  end

  def get_user(id), do: Repo.get(UserAuth, id)

  def get_by_phone_number(phone_number) do
    Repo.get_by(UserAuth, phone_number: phone_number)
  end

  @doc """
  Public-safe phone → user lookup for starting a direct (1:1) chat.

  Returns `{:ok, %{user_id: id}}` for an ACTIVE account whose `phone_number` matches exactly, and
  `{:error, :not_found}` for an unknown number OR a non-active (suspended/deleted) account — a caller
  can't distinguish "no such number" from "suspended". The match is exact: the stored phone is the
  same E.164 the client emits at login (`normalize_destination/1` only trims), so an E.164 lookup
  matches with no fuzzy logic. Email-registered users (phone_number nil) are simply never found.

  APP-SCOPED when `app_id` is given (the gateway always supplies the caller's tenant): the match is
  `WHERE app_id = $1 AND phone_number = $2 AND status = 'active'`. This is the correct multi-tenant
  lookup — under migration 048's per-(app_id, phone_number) uniqueness the same number can exist in
  two tenants, so an app-blind match could resolve ANOTHER tenant's user. Without `app_id` it falls
  back to the LEGACY app-blind path (only `RealtimeGateway.CallSignaling` still lands there — see the
  follow-up note there) so no caller regresses.
  """
  def lookup_active_by_phone(phone_number, app_id \\ nil)

  def lookup_active_by_phone(phone_number, app_id)
      when is_binary(phone_number) and is_binary(app_id) and app_id != "" do
    case active_by_phone(String.trim(phone_number), app_id) do
      %UserAuth{id: id} -> {:ok, %{user_id: id}}
      _ -> {:error, :not_found}
    end
  end

  def lookup_active_by_phone(phone_number, _app_id) when is_binary(phone_number) do
    # LEGACY app-blind path (no tenant scope). Kept only so callers that don't yet pass app_id keep
    # working unchanged; the app-scoped clause above is the correct one. Discoverability applies here
    # too — a non-discoverable user is absent from EVERY phone-resolution path.
    with %UserAuth{id: id, status: "active"} <- get_by_phone_number(String.trim(phone_number)),
         true <- discoverable_by_phone?(id) do
      {:ok, %{user_id: id}}
    else
      _ -> {:error, :not_found}
    end
  end

  def lookup_active_by_phone(_phone_number, _app_id), do: {:error, :not_found}

  @doc """
  Bulk phone → user_id resolution for CONTACTS SYNC, scoped to `app_id` (the caller's tenant).

  ONE query regardless of list size — `WHERE app_id = $1 AND status = 'active' AND phone_number =
  ANY($2)` — which is the whole point: this is the API's best enumeration oracle, so its cost must
  not scale with the batch. Returns `{:ok, [%{user_id, phone_number}]}` for the ACTIVE matches only
  (unknown/suspended numbers are simply absent — never a "not found" row). The list is trimmed +
  de-duped defensively here; E.164 shape-validation + the batch-size cap live at the gateway. The
  echoed `phone_number` is the stored value, which (exact match) equals the caller's input so the
  client can join results back to its address book.
  """
  def lookup_active_by_phones(phone_numbers, app_id)
      when is_list(phone_numbers) and is_binary(app_id) and app_id != "" do
    normalized =
      phone_numbers
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    {:ok, active_by_phones(normalized, app_id)}
  end

  def lookup_active_by_phones(_phone_numbers, _app_id), do: {:ok, []}

  # Single app-scoped row (or nil). The (app_id, phone_number) partial unique index makes this at most
  # one row; `limit: 1` is belt-and-suspenders. DISCOVERABILITY (084) is folded into the SAME query the
  # single lookup, the bulk contacts sync, AND call-add-by-phone all resolve through — one predicate,
  # no drift, no extra queries: LEFT JOIN so no-row/NULL reads as the default (discoverable).
  defp active_by_phone(phone, app_id) do
    Repo.one(
      from(u in UserAuth,
        left_join: ps in "user_privacy_settings",
        on: ps.user_id == u.id,
        where: u.app_id == ^app_id and u.status == "active" and u.phone_number == ^phone,
        where: is_nil(ps.discoverable_by_phone) or ps.discoverable_by_phone,
        limit: 1
      )
    )
  end

  defp active_by_phones([], _app_id), do: []

  defp active_by_phones(phones, app_id) do
    Repo.all(
      from(u in UserAuth,
        left_join: ps in "user_privacy_settings",
        on: ps.user_id == u.id,
        where: u.app_id == ^app_id and u.status == "active" and u.phone_number in ^phones,
        where: is_nil(ps.discoverable_by_phone) or ps.discoverable_by_phone,
        select: %{user_id: u.id, phone_number: u.phone_number}
      )
    )
  end

  # The legacy app-blind clause can't join in its Repo.get_by, so it checks the flag separately —
  # same `IS NOT FALSE` semantics (no row / NULL = discoverable).
  defp discoverable_by_phone?(user_id) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM user_privacy_settings WHERE user_id = $1::text::uuid AND discoverable_by_phone = false",
        [user_id]
      )

    rows == []
  rescue
    _ -> true
  end

  @doc """
  Resolve an integrator's opaque end-user id to a stable user row WITHIN an app, creating it on first
  sight. Idempotent: a second call (or a concurrent race on the (app_id, external_id) unique index)
  returns the SAME user. App-A's "alice" and App-B's "alice" are different rows (multi-tenancy).
  """
  def resolve_or_create_external_user(app_id, external_id)
      when is_binary(app_id) and app_id != "" and is_binary(external_id) and external_id != "" do
    case get_external_user(app_id, external_id) do
      %UserAuth{id: id} ->
        {:ok, %{user_id: id}}

      nil ->
        %UserAuth{}
        |> UserAuth.changeset(%{
          "id" => Ecto.UUID.generate(),
          "app_id" => app_id,
          "external_id" => external_id,
          "status" => "active"
        })
        |> Repo.insert()
        |> case do
          {:ok, user} ->
            {:ok, %{user_id: user.id}}

          {:error, %Ecto.Changeset{errors: errors}} ->
            # Race: another request created it first → re-fetch and return that one.
            if Keyword.has_key?(errors, :external_id) do
              case get_external_user(app_id, external_id) do
                %UserAuth{id: id} -> {:ok, %{user_id: id}}
                nil -> {:error, :user_invalid}
              end
            else
              {:error, :user_invalid}
            end
        end
    end
  end

  def resolve_or_create_external_user(_app_id, _external_id), do: {:error, :user_invalid}

  @doc """
  Resolve-ONLY twin of `resolve_or_create_external_user/2`, for LOOKUP/reference contexts (a GET, a callee
  check, a presence subscribe): the SAME `(app_id, external_id)` scoping and the same lookup, but an unknown
  id is `{:error, :user_not_found}` — never a created row. JIT provisioning stays exclusive to the WRITE
  contexts (message sender / media owner / conversation participants), where creating on first sight is the
  point; a read path creating user rows was the defect this exists to close.
  """
  def lookup_external_user(app_id, external_id)
      when is_binary(app_id) and app_id != "" and is_binary(external_id) and external_id != "" do
    case get_external_user(app_id, external_id) do
      %UserAuth{id: id} -> {:ok, %{user_id: id}}
      nil -> {:error, :user_not_found}
    end
  end

  def lookup_external_user(_app_id, _external_id), do: {:error, :user_not_found}

  @doc """
  Reverse of `resolve_or_create_external_user`: map an internal `user_id` back to the integrator's
  `external_id` WITHIN an app. The `app_id` scope makes this double as a tenant check — a user_id that
  doesn't belong to `app_id` (cross-tenant, or a phone/email session user with no external_id) → `:not_found`.
  Never creates. Returns `{:ok, %{user_id, external_id}}` | `{:error, :not_found}`.
  """
  def external_id_for_user(app_id, user_id)
      when is_binary(app_id) and app_id != "" and is_binary(user_id) and user_id != "" do
    case Repo.get_by(UserAuth, id: user_id, app_id: app_id) do
      %UserAuth{external_id: external_id} when is_binary(external_id) and external_id != "" ->
        {:ok, %{user_id: user_id, external_id: external_id}}

      _ ->
        {:error, :not_found}
    end
  end

  def external_id_for_user(_app_id, _user_id), do: {:error, :not_found}

  defp get_external_user(app_id, external_id),
    do: Repo.get_by(UserAuth, app_id: app_id, external_id: external_id)

  # APP-SCOPED, and case-folded to match users_auth_email_key (091). The previous 1-arity version was
  # APP-BLIND — and since 048 made email per-tenant unique, two tenants may legitimately hold one
  # address, at which point `Repo.get_by` raises Ecto.MultipleResultsError. So the old function
  # returned another tenant's user OR crashed; neither is a login. Its only caller was the email-OTP
  # branch, which now refuses outright (see AuthService.OTP) because email here is an UNVERIFIED
  # contact detail, not an identity.
  def get_by_email(app_id, email) when is_binary(app_id) and is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()

    case Repo.query(
           "SELECT id::text FROM users_auth " <>
             "WHERE app_id = $1::text::uuid AND lower(email) = $2 LIMIT 1",
           [app_id, normalized]
         ) do
      {:ok, %{rows: [[id]]}} -> Repo.get(UserAuth, id)
      _ -> nil
    end
  end

  @email_max_length 254

  @doc """
  Set or clear the caller's email — an UNVERIFIED CONTACT DETAIL, never an identity: it does not log
  anyone in, does not recover an account, and is not discoverable. See DECISION_LOG.

  Normalised to lowercase (one canonical form; the 091 index folds too, so a case variant of an
  address already in this tenant is `:email_taken`). Clearing is allowed ONLY while another
  identifier remains — the users_auth_identity_check requires phone OR email OR external_id, and a
  user must not be able to strip their last one (that would be an unrecoverable account, enforced
  here with a clean code instead of a raw constraint error).
  """
  # app_id is not a query parameter here: the row is fetched by its own id and tenanted uniqueness is
  # enforced by the 091 index, not by a WHERE. It stays in the signature so callers must pass the
  # session's tenant — a future per-tenant policy has it without a signature change.
  def update_email(_app_id, user_id, email) do
    with {:ok, user} <- fetch_user(user_id),
         {:ok, normalized} <- normalize_email(email),
         :ok <- keeps_an_identifier(user, normalized) do
      user
      |> UserAuth.changeset(%{"email" => normalized})
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          {:ok, %{user_id: updated.id, email: updated.email}}

        {:error, %Ecto.Changeset{}} ->
          {:error, :email_invalid}
      end
    end
  rescue
    # The 091 index is the race-safe authority: a duplicate inside this tenant surfaces here, and it
    # is a TAKEN address, not an invalid one. Ecto raises ConstraintError for an index violation with
    # no matching unique_constraint/3 on the changeset; Postgrex.Error is the raw-SQL shape. Both
    # mean the same thing — caught together rather than relying on which layer reports it.
    Ecto.ConstraintError -> {:error, :email_taken}
    Postgrex.Error -> {:error, :email_taken}
    Ecto.Query.CastError -> {:error, :email_invalid}
  end

  defp fetch_user(user_id) do
    case Repo.get(UserAuth, user_id) do
      %UserAuth{} = user -> {:ok, user}
      _ -> {:error, :user_not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :user_not_found}
  end

  # Deliberately PRAGMATIC, not RFC 5322: one @, a non-empty local part, a dotted domain, no
  # whitespace, <= 254 bytes (RFC 5321's path limit). Full RFC validation rejects addresses that
  # work and accepts ones that don't — the real check is whether mail arrives, which we do not do.
  defp normalize_email(nil), do: {:ok, nil}
  defp normalize_email(""), do: {:ok, nil}

  defp normalize_email(email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()

    cond do
      normalized == "" ->
        {:ok, nil}

      String.length(normalized) > @email_max_length ->
        {:error, :email_invalid}

      not Regex.match?(~r/^[^\s@]+@[^\s@.]+(\.[^\s@.]+)+$/u, normalized) ->
        {:error, :email_invalid}

      true ->
        {:ok, normalized}
    end
  end

  defp normalize_email(_), do: {:error, :email_invalid}

  defp keeps_an_identifier(_user, email) when is_binary(email), do: :ok

  defp keeps_an_identifier(%UserAuth{} = user, nil) do
    if present?(user.phone_number) or present?(user.external_id),
      do: :ok,
      else: {:error, :email_last_identifier}
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  @doc """
  Sets a user's `status` (active | suspended | deleted) via the validated changeset. Used by admin
  moderation. `Sessions.active_user/1` already rejects any non-active status, so suspending blocks the
  user at the auth layer on their next request.
  """
  def set_status(user_id, status) do
    case Repo.get(UserAuth, user_id) do
      nil ->
        {:error, :user_not_found}

      %UserAuth{} = user ->
        user
        |> UserAuth.changeset(%{"status" => status})
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, updated}
          {:error, _changeset} -> {:error, :invalid_status}
        end
    end
  rescue
    Ecto.Query.CastError -> {:error, :user_not_found}
  end

  @doc "Paginated user list for the admin moderation table. Optional status filter + phone/email search."
  def list_users(opts \\ %{}) do
    page = page(opts)
    page_size = 25
    offset = (page - 1) * page_size

    # Admin console is first-party only → always scope to the tenant (default tenant-zero when unset).
    {where, params} = list_filters(opts)

    # uuid columns must be ::text — raw Repo.query! returns uuid as a 16-byte binary that Jason can't encode.
    # LEFT JOIN user_profiles for display_name (same shared DB; admin-gated list). role comes from
    # users_auth (mig 058). ua.* is qualified because both tables have a created_at column.
    sql =
      "SELECT ua.id::text, ua.phone_number, ua.email, ua.status, ua.is_admin, ua.role, up.display_name, " <>
        "to_char(ua.created_at, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS created_at " <>
        "FROM users_auth ua LEFT JOIN user_profiles up ON up.user_id = ua.id " <>
        "#{where} ORDER BY ua.created_at DESC LIMIT #{page_size} OFFSET #{offset}"

    %Postgrex.Result{rows: rows} = Repo.query!(sql, params)

    %{
      page: page,
      page_size: page_size,
      users:
        Enum.map(rows, fn [id, phone, email, status, is_admin, role, display_name, created_at] ->
          %{
            user_id: id,
            phone_number: phone,
            email: email,
            status: status,
            is_admin: is_admin,
            role: role,
            display_name: display_name,
            created_at: created_at
          }
        end)
    }
  end

  # Batched user summaries by id — {user_id, display_name, phone_number} for admin views that only have
  # raw ids (message senders, report/audit actors). ONE query (no N+1); admin-gated at the gateway. Phone
  # is included because the admin context is allowed to see it.
  def list_user_summaries(attrs \\ %{}) do
    ids =
      (Map.get(attrs, "user_ids") || Map.get(attrs, :user_ids) || [])
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if ids == [] do
      %{summaries: []}
    else
      sql =
        "SELECT ua.id::text, up.display_name, ua.phone_number " <>
          "FROM users_auth ua LEFT JOIN user_profiles up ON up.user_id = ua.id " <>
          "WHERE ua.id::text = ANY($1)"

      %Postgrex.Result{rows: rows} = Repo.query!(sql, [ids])

      %{
        summaries:
          Enum.map(rows, fn [id, display_name, phone] ->
            %{user_id: id, display_name: display_name, phone_number: phone}
          end)
      }
    end
  rescue
    _ -> %{summaries: []}
  end

  # Builds the WHERE clause + positional params for the optional status filter and phone/email search.
  defp list_filters(opts) do
    # app_id is ALWAYS $1 (tenant scope, default tenant-zero); optional filters take $2, $3.
    app = SharedInfra.Tenancy.app_id_or_default(present(Map.get(opts, "app_id")))
    {clauses, params, i} = {["ua.app_id = $1"], [uuid_param(app)], 2}

    {clauses, params, i} =
      case present(Map.get(opts, "status")) do
        nil -> {clauses, params, i}
        status -> {clauses ++ ["status = $#{i}"], params ++ [status], i + 1}
      end

    {clauses, params} =
      case present(Map.get(opts, "q")) do
        nil ->
          {clauses, params}

        q ->
          {clauses ++ ["(phone_number ILIKE $#{i} OR email ILIKE $#{i})"], params ++ ["%#{q}%"]}
      end

    {"WHERE " <> Enum.join(clauses, " AND "), params}
  end

  defp page(opts) do
    case Map.get(opts, "page") do
      n when is_integer(n) and n > 0 ->
        n

      n when is_binary(n) ->
        case Integer.parse(n) do
          {p, _} when p > 0 -> p
          _ -> 1
        end

      _ ->
        1
    end
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  # uuid columns need the 16-byte binary, not the string form.
  defp uuid_param(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, binary} -> binary
      :error -> value
    end
  end
end
