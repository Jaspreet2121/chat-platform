defmodule AuthService.ApiKeys do
  @moduledoc """
  Secret API keys per app (tenant). The credential an integrator's SERVER presents to call `/v1`.

  SECURITY: the raw key (`sk_live_…`) is generated from a CSPRNG, returned to the caller exactly ONCE
  at creation, and NEVER stored or logged. Only `sha256(key)` (key_hash) + a short non-secret prefix
  are persisted. Verification hashes the presented key and does an indexed exact lookup on key_hash —
  so there is no "prefix matched but full didn't" path to leak, and the comparison is the DB's hash
  equality (effectively constant-time vs. a naive string compare of the secret).
  """

  import Ecto.Query

  alias AuthService.Repo
  alias AuthService.Schemas.ApiKey

  @key_type_prefix "sk_live_"

  @doc "Create a key for an app. Returns the FULL raw key ONCE under :api_key (never stored/logged)."
  def create_api_key(attrs) do
    with {:ok, app_id} <- fetch(attrs, "app_id"),
         {:ok, name} <- fetch(attrs, "name") do
      {raw, prefix, hash} = generate_key()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      %ApiKey{}
      |> ApiKey.changeset(%{
        "app_id" => app_id,
        "name" => name,
        "key_hash" => hash,
        "key_prefix" => prefix,
        "created_at" => now
      })
      |> Repo.insert()
      |> case do
        {:ok, key} ->
          {:ok,
           %{
             id: key.id,
             app_id: key.app_id,
             name: key.name,
             key_prefix: key.key_prefix,
             created_at: iso(key.created_at),
             # Shown exactly once — the caller must store it now; it is unrecoverable afterward.
             api_key: raw
           }}

        {:error, _changeset} ->
          {:error, :api_key_invalid}
      end
    end
  end

  @doc "List an app's keys — metadata + prefix only, NEVER the secret or its hash."
  def list_api_keys(attrs) do
    with {:ok, app_id} <- fetch(attrs, "app_id") do
      keys =
        Repo.all(from(k in ApiKey, where: k.app_id == ^app_id, order_by: [desc: k.created_at]))

      {:ok, %{api_keys: Enum.map(keys, &public_view/1)}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :api_key_invalid}
  end

  @doc "Revoke one of THIS app's keys (scoped by app_id so an app can't revoke another's)."
  def revoke_api_key(attrs) do
    with {:ok, app_id} <- fetch(attrs, "app_id"),
         {:ok, id} <- fetch(attrs, "id") do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      query =
        from(k in ApiKey,
          where: k.id == ^id and k.app_id == ^app_id and is_nil(k.revoked_at)
        )

      case Repo.update_all(query, set: [revoked_at: now]) do
        {1, _} -> {:ok, %{id: id, revoked: true}}
        {0, _} -> {:error, :not_found}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :api_key_invalid}
  end

  @doc """
  Verify a presented raw key → {:ok, %{app_id, api_key_id}} for an ACTIVE (non-revoked) key, else
  {:error, :invalid_api_key}. Bumps last_used_at. Used by the `/v1` secret-key auth plug (Phase 2).
  """
  def verify_api_key(raw) when is_binary(raw) and raw != "" do
    hash = hash_key(raw)

    case Repo.one(from(k in ApiKey, where: k.key_hash == ^hash)) do
      %ApiKey{revoked_at: nil} = key ->
        Repo.update_all(from(k in ApiKey, where: k.id == ^key.id),
          set: [last_used_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)]
        )

        {:ok, %{app_id: key.app_id, api_key_id: key.id}}

      _ ->
        {:error, :invalid_api_key}
    end
  end

  def verify_api_key(_raw), do: {:error, :invalid_api_key}

  # --- internals -------------------------------------------------------------------------------

  defp generate_key do
    random = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    raw = @key_type_prefix <> random
    # Non-secret display slice: "sk_live_" + 8 chars of the random body.
    prefix = String.slice(raw, 0, 16)
    {raw, prefix, hash_key(raw)}
  end

  defp hash_key(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  defp public_view(%ApiKey{} = key) do
    %{
      id: key.id,
      name: key.name,
      key_prefix: key.key_prefix,
      created_at: iso(key.created_at),
      last_used_at: iso(key.last_used_at),
      revoked_at: iso(key.revoked_at),
      revoked: not is_nil(key.revoked_at)
    }
  end

  defp fetch(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :api_key_invalid}
    end
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
