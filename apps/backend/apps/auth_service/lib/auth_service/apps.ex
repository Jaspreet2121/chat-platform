defmodule AuthService.Apps do
  @moduledoc """
  Self-serve integrator apps (WhatsApp-Business-style). A first-party user registers a business "app"
  and becomes its owner; app-scoped actions are then authorized against `app_owners`. Each registered
  app is a DISTINCT live app_id — the existing app_id seal (V1Auth / realtime / webhook registration)
  isolates integrators for free, and the test-twin allocator (`AuthService.ApiKeys`) derives a per-app
  twin off whichever live app_id it's handed.

  Raw SQL over `AuthService.Repo` (uuid params via the `::text::uuid` cast), mirroring the twin
  allocator — there is no Ecto schema for `apps`. Ownership is recorded ONLY for live apps a user
  creates; twins are never owned directly.
  """

  alias AuthService.Repo

  @doc """
  Register a new LIVE app owned by `owner_user_id`. Allocates a fresh app row (mode='live',
  parent_app_id=NULL) and records the caller as its owner, atomically. Returns %{app_id, name, mode}.
  """
  def create_app(attrs) do
    with {:ok, owner_user_id} <- fetch(attrs, "owner_user_id"),
         {:ok, name} <- fetch(attrs, "name") do
      slug = slugify(name)

      Repo.transaction(fn ->
        with {:ok, %{rows: [[app_id]]}} <-
               Repo.query(
                 "INSERT INTO apps (id, name, slug, mode, parent_app_id) " <>
                   "VALUES (gen_random_uuid(), $1, $2, 'live', NULL) RETURNING id::text",
                 [name, slug]
               ),
             {:ok, _} <-
               Repo.query(
                 "INSERT INTO app_owners (app_id, owner_user_id, role) " <>
                   "VALUES ($1::text::uuid, $2::text::uuid, 'owner')",
                 [app_id, owner_user_id]
               ) do
          %{app_id: app_id, name: name, mode: "live"}
        else
          _ -> Repo.rollback(:app_invalid)
        end
      end)
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, _} -> {:error, :app_invalid}
      end
    end
  end

  @doc "List the LIVE apps `owner_user_id` owns (newest first). Twins are never listed (never owned)."
  def list_apps(attrs) do
    with {:ok, owner_user_id} <- fetch(attrs, "owner_user_id") do
      case Repo.query(
             "SELECT a.id::text, a.name, a.mode, a.created_at::text " <>
               "FROM apps a JOIN app_owners o ON o.app_id = a.id " <>
               "WHERE o.owner_user_id = $1::text::uuid ORDER BY a.created_at DESC",
             [owner_user_id]
           ) do
        {:ok, %{rows: rows}} ->
          {:ok,
           %{
             apps:
               Enum.map(rows, fn [id, name, mode, created_at] ->
                 %{app_id: id, name: name, mode: mode, created_at: created_at}
               end)
           }}

        _ ->
          {:error, :app_invalid}
      end
    end
  rescue
    _ -> {:error, :app_invalid}
  end

  @doc """
  Authorize that `owner_user_id` owns `app_id`. {:ok, %{app_id}} if owned, else {:error, :forbidden}.
  The single gate every app-scoped action runs before acting AS an app_id.
  """
  def owns_app(attrs) do
    with {:ok, owner_user_id} <- fetch(attrs, "owner_user_id"),
         {:ok, app_id} <- fetch(attrs, "app_id") do
      case Repo.query(
             "SELECT 1 FROM app_owners WHERE app_id = $1::text::uuid AND owner_user_id = $2::text::uuid LIMIT 1",
             [app_id, owner_user_id]
           ) do
        {:ok, %{rows: [[_]]}} -> {:ok, %{app_id: app_id}}
        _ -> {:error, :forbidden}
      end
    end
  rescue
    # Malformed uuid etc → treat as not-owned (never leak that an app exists in another owner's account).
    _ -> {:error, :forbidden}
  end

  # --- internals -------------------------------------------------------------------------------

  # Non-secret internal slug; name-derived prefix + random suffix so it never collides (slug is UNIQUE).
  defp slugify(name) do
    prefix =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)

    prefix = if prefix == "", do: "app", else: prefix
    prefix <> "-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
  end

  @doc """
  Owner-facing ENTITY COUNTS for ONE app: `%{users, conversations, messages, storage_bytes}`.

  Every number is a real query — nothing is estimated. `app_id` is mandatory and is the tenant boundary.

  MESSAGES are counted via the PARENT CONVERSATION (`JOIN conversations c ON c.id = m.conversation_id
  WHERE c.app_id`), never `messages.app_id`. `messages.app_id` is stamped from the conversation on write
  today, but rows written before that stamp landed carry the tenant-zero default — the conversation is the
  authoritative tenant of a message either way, so the join is correct for ALL rows, old and new.

  NOTE: counts only. No message content is read, and nothing here is cross-tenant.
  """
  def app_usage(attrs) do
    with {:ok, app_id} <- fetch(attrs, "app_id") do
      {:ok,
       %{
         app_id: app_id,
         users: scalar("SELECT count(*) FROM users_auth WHERE app_id = $1::text::uuid", app_id),
         conversations:
           scalar("SELECT count(*) FROM conversations WHERE app_id = $1::text::uuid", app_id),
         messages:
           scalar(
             "SELECT count(*) FROM messages m JOIN conversations c ON c.id = m.conversation_id " <>
               "WHERE c.app_id = $1::text::uuid",
             app_id
           ),
         storage_bytes:
           scalar(
             "SELECT COALESCE(SUM(size_bytes), 0)::bigint FROM media_assets WHERE app_id = $1::text::uuid",
             app_id
           )
       }}
    end
  rescue
    Ecto.Query.CastError -> {:error, :app_invalid}
    Postgrex.Error -> {:error, :app_invalid}
  end

  defp scalar(sql, app_id) do
    case Repo.query(sql, [app_id]) do
      {:ok, %{rows: [[value]]}} when is_integer(value) -> value
      _ -> 0
    end
  end

  defp fetch(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :app_invalid}
    end
  end
end
