defmodule ApiGatewayWeb.LinkStore do
  @moduledoc """
  Short-lived state for the QR link flow (LinkController) — a thin, swappable seam over
  `SharedInfra.RedisKV` so the flow's logic is deterministically testable without Redis.

  Semantics the flow depends on:
    * `put/3` — SET with TTL (seconds).
    * `get/1` — {:ok, value} | :not_found | {:error, reason}.
    * `put_get/3` — atomic SET..GET (the previous value comes back). This is what makes token
      retrieval SINGLE-USE: two racing polls both write "consumed", but only ONE gets the
      approved-state previous value back — the other sees "consumed" and returns nothing.
    * `del/1` — best-effort delete.

  Adapter via `:api_gateway, :link_store_adapter` (defaults to the Redis implementation below).
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
    do: Application.get_env(:api_gateway, :link_store_adapter, ApiGatewayWeb.LinkStore.Redis)

  defmodule Redis do
    @moduledoc false
    @behaviour ApiGatewayWeb.LinkStore

    @impl true
    def put(key, value, ttl), do: SharedInfra.RedisKV.put(key, value, ttl)

    @impl true
    def get(key) do
      case SharedInfra.RedisKV.get(key) do
        {:ok, :null} -> :not_found
        {:ok, value} when is_binary(value) -> {:ok, value}
        {:ok, _other} -> :not_found
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def put_get(key, value, ttl), do: SharedInfra.RedisKV.put_get(key, value, ttl)

    @impl true
    def del(key), do: SharedInfra.RedisKV.del(key)
  end
end
