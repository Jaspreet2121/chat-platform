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
    sql =
      "SELECT id::text, phone_number, email, status, is_admin, " <>
        "to_char(created_at, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS created_at " <>
        "FROM users_auth #{where} ORDER BY created_at DESC LIMIT #{page_size} OFFSET #{offset}"

    %Postgrex.Result{rows: rows} = Repo.query!(sql, params)

    %{
      page: page,
      page_size: page_size,
      users:
        Enum.map(rows, fn [id, phone, email, status, is_admin, created_at] ->
          %{
            user_id: id,
            phone_number: phone,
            email: email,
            status: status,
            is_admin: is_admin,
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
