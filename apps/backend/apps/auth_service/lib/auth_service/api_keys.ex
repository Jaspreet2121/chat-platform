defmodule AuthService.ApiKeys do
  require Logger

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

  @doc """
  Create a key for an app. `mode` is "live" (default) or "test". A TEST key is stored against the
  integrator's DISTINCT test-twin app_id (allocated/linked here), so the existing app_id seal isolates
  its data from live — no per-row mode predicate anywhere. Returns the FULL raw key ONCE.
  """
  def create_api_key(attrs) do
    with {:ok, app_id} <- fetch(attrs, "app_id"),
         {:ok, name} <- fetch(attrs, "name"),
         {:ok, mode} <- fetch_mode(attrs),
         {:ok, effective_app_id} <- effective_app_id(app_id, mode) do
      {raw, prefix, hash} = generate_key(mode)
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      %ApiKey{}
      |> ApiKey.changeset(%{
        # For a test key this is the TEST TWIN app_id (distinct from the live app_id) — the isolation.
        "app_id" => effective_app_id,
        "name" => name,
        "key_hash" => hash,
        "key_prefix" => prefix,
        "mode" => mode,
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
             mode: key.mode,
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

        # app_id already differs by mode (a test key's app_id is its twin); mode is returned so the
        # plug/socket can surface app_mode. Isolation stays purely on app_id — no mode predicate.
        {:ok, %{app_id: key.app_id, api_key_id: key.id, mode: key.mode || "live"}}

      _ ->
        {:error, :invalid_api_key}
    end
  end

  def verify_api_key(_raw), do: {:error, :invalid_api_key}

  # --- internals -------------------------------------------------------------------------------

  defp fetch_mode(attrs) do
    case Map.get(attrs, "mode") do
      nil -> {:ok, "live"}
      mode when mode in ["live", "test"] -> {:ok, mode}
      _ -> {:error, :api_key_invalid}
    end
  end

  # A live key keeps the caller's app_id; a test key resolves to the integrator's test-twin app_id.
  defp effective_app_id(app_id, "test"), do: resolve_or_create_test_twin(app_id)

  # A live key never lands on a test app. Unreachable before the gap-4 owns_app widening (a twin
  # app_id 403'd at the console gate); now an owner CAN name their twin here, and without this
  # guard that would mint an sk_live_ credential bound to a test tenant. Twins stay leaf-only —
  # the same rule allocate_twin's `p.mode = 'live'` enforces for sk_test_.
  defp effective_app_id(app_id, _live) do
    case Repo.query(
           "SELECT 1 FROM apps WHERE id = $1::text::uuid AND mode = 'test' LIMIT 1",
           [app_id]
         ) do
      {:ok, %{rows: []}} -> {:ok, app_id}
      _ -> {:error, :api_key_invalid}
    end
  end

  # Find-or-create the ONE test twin app for a live app. The fast path is the SELECT (the twin
  # exists for every key after the integrator's first); the miss path is atomic:
  # INSERT ... ON CONFLICT DO NOTHING + a GUARANTEED follow-up SELECT (`allocate_twin/1`).
  defp resolve_or_create_test_twin(live_app_id) do
    case twin_of(live_app_id) do
      {:ok, twin_id} -> {:ok, twin_id}
      :none -> allocate_twin(live_app_id)
      :error -> {:error, :api_key_invalid}
    end
  end

  @doc false
  # The atomic miss path, public for the race tests (the commit_decision precedent) — the raced
  # branch is unreachable through the public API without a genuine concurrent loser.
  #
  # THE ON CONFLICT TARGET IS NAMED, not bare: `(parent_app_id) WHERE mode = 'test'` cites the
  # partial unique index apps_test_twin_unique (054). Bare ON CONFLICT DO NOTHING on this table
  # would ALSO swallow a collision on apps.slug (048: slug UNIQUE) — an integrator whose live slug
  # is 'foo' racing a real app named 'foo-test' — and the follow-up SELECT would then find no twin
  # and return a misleading error with no evidence. Targeted, the slug collision still RAISES and
  # is logged below as what it actually is.
  #
  # ON CONFLICT DO NOTHING RETURNS ZERO ROWS for the conflicted (raced-loser) case — RETURNING
  # yields nothing precisely when the twin already exists. The follow-up SELECT is therefore NOT
  # optional; zero rows also covers "live app does not exist", and the SELECT distinguishes the two.
  def allocate_twin(live_app_id) do
    case Repo.query(
           # `p.mode = 'live'`: twins are LEAVES. The gap-4 owns_app widening lets an owner name
           # their twin as the target app; without this guard a test key against the twin would
           # allocate a twin-of-twin (the partial index only dedupes per parent, it would not stop
           # a second generation). Zero rows here → the follow-up SELECT reports :api_key_invalid.
           "INSERT INTO apps (id, name, slug, parent_app_id, mode) " <>
             "SELECT gen_random_uuid(), p.name || ' (test)', p.slug || '-test', p.id, 'test' " <>
             "FROM apps p WHERE p.id = $1::text::uuid AND p.mode = 'live' " <>
             "ON CONFLICT (parent_app_id) WHERE mode = 'test' DO NOTHING " <>
             "RETURNING id::text",
           [live_app_id]
         ) do
      {:ok, %{rows: [[twin_id]]}} ->
        {:ok, twin_id}

      {:ok, %{rows: []}} ->
        # Raced loser (twin exists) or nonexistent live app — the guaranteed SELECT decides.
        case twin_of(live_app_id) do
          {:ok, twin_id} -> {:ok, twin_id}
          _ -> {:error, :api_key_invalid}
        end

      {:error, %Postgrex.Error{postgres: %{code: :unique_violation}} = error} ->
        # NOT the twin index (the ON CONFLICT target absorbs that): this is the slug collision.
        # Loud, because the integrator's test mode is unusable until the clash is resolved and
        # a silent :api_key_invalid would read as a credentials problem.
        Logger.warning(
          "test-twin allocation for #{live_app_id} hit a UNIQUE collision outside the twin " <>
            "index (almost certainly apps.slug '-test' clash): #{inspect(error.postgres)}"
        )

        {:error, :api_key_invalid}

      _ ->
        {:error, :api_key_invalid}
    end
  end

  defp twin_of(live_app_id) do
    case Repo.query(
           "SELECT id::text FROM apps WHERE parent_app_id = $1::text::uuid AND mode = 'test' LIMIT 1",
           [live_app_id]
         ) do
      {:ok, %{rows: [[twin_id]]}} -> {:ok, twin_id}
      {:ok, %{rows: []}} -> :none
      _ -> :error
    end
  end

  defp generate_key(mode) do
    random = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    raw = key_type_prefix(mode) <> random
    # Non-secret display slice: "sk_live_"/"sk_test_" + 8 chars of the random body.
    prefix = String.slice(raw, 0, 16)
    {raw, prefix, hash_key(raw)}
  end

  defp key_type_prefix("test"), do: "sk_test_"
  defp key_type_prefix(_live), do: "sk_live_"

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
