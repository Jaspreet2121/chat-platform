defmodule AuthService.Accounts do
  @moduledoc """
  Data-access boundary for auth identities in `users_auth`.
  """

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
  """
  def lookup_active_by_phone(phone_number) when is_binary(phone_number) do
    case get_by_phone_number(String.trim(phone_number)) do
      %UserAuth{id: id, status: "active"} -> {:ok, %{user_id: id}}
      _ -> {:error, :not_found}
    end
  end

  def lookup_active_by_phone(_phone_number), do: {:error, :not_found}

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

  defp get_external_user(app_id, external_id),
    do: Repo.get_by(UserAuth, app_id: app_id, external_id: external_id)

  def get_by_email(email) do
    Repo.get_by(UserAuth, email: email)
  end

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

  # Builds the WHERE clause + positional params for the optional status filter and phone/email search.
  defp list_filters(opts) do
    acc0 = {[], [], 1}

    {clauses, params, i} =
      case present(Map.get(opts, "status")) do
        nil -> acc0
        status -> {["status = $1"], [status], 2}
      end

    {clauses, params} =
      case present(Map.get(opts, "q")) do
        nil ->
          {clauses, params}

        q ->
          {clauses ++ ["(phone_number ILIKE $#{i} OR email ILIKE $#{i})"], params ++ ["%#{q}%"]}
      end

    where = if clauses == [], do: "", else: "WHERE " <> Enum.join(clauses, " AND ")
    {where, params}
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
end
