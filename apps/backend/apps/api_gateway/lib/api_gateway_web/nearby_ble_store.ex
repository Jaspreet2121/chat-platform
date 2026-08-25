defmodule ApiGatewayWeb.NearbyBleStore do
  @moduledoc """
  Short-lived BLE state for Nearby v2 (the LinkStore seam precedent) — a thin, swappable layer over
  `SharedInfra.RedisKV` so the token/sighting logic is deterministically testable without Redis.

  Three key families, ALL TTL-bound, NOTHING persisted:
    * `nearby:ble:tok:<token>`  → "user_id|app_id", TTL 300 — a broadcast token, meaningless to
      anyone but the server (16 CSPRNG bytes; carries no identity, resolves only here).
    * `nearby:ble:cur:<user>`   → the user's current token, TTL 300 — `put_get` makes re-request
      ROTATION atomic: the previous token comes back in one round trip and is deleted, so at most
      one token per user resolves at any moment.
    * `nearby:ble:prox:<viewer>:<target>` → "1", TTL 120 — a proximity marker; while it lives the
      discover overlay shows bucket "ble" for that pair. Expiry IS the revert — no cleanup path.

  Adapter via `:api_gateway, :nearby_ble_store_adapter` (defaults to Redis below).
  """

  @callback put(String.t(), String.t(), pos_integer()) :: :ok | {:error, term()}
  @callback get(String.t()) :: {:ok, String.t()} | :not_found | {:error, term()}
  @callback put_get(String.t(), String.t(), pos_integer()) ::
              {:ok, :was_absent} | {:ok, {:was_present, String.t()}} | {:error, term()}
  @callback del(String.t()) :: :ok | {:error, term()}

  def put(key, value, ttl), do: adapter().put(key, value, ttl)
  def get(key), do: adapter().get(key)
  def put_get(key, value, ttl), do: adapter().put_get(key, value, ttl)
  def del(key), do: adapter().del(key)

  defp adapter,
    do:
      Application.get_env(
        :api_gateway,
        :nearby_ble_store_adapter,
        ApiGatewayWeb.NearbyBleStore.Redis
      )

  defmodule Redis do
    @moduledoc false
    @behaviour ApiGatewayWeb.NearbyBleStore

    @impl true
    def put(key, value, ttl), do: SharedInfra.RedisKV.put(key, value, ttl)

    @impl true
    def get(key) do
      case SharedInfra.RedisKV.get(key) do
        {:ok, value} when is_binary(value) -> {:ok, value}
        :miss -> :not_found
        {:error, reason} -> {:error, reason}
        _ -> :not_found
      end
    end

    @impl true
    def put_get(key, value, ttl), do: SharedInfra.RedisKV.put_get(key, value, ttl)

    @impl true
    def del(key), do: SharedInfra.RedisKV.del(key)
  end
end
