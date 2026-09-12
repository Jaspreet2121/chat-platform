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

    require Logger

    @impl true
    def put(key, value, ttl), do: SharedInfra.RedisKV.put(key, value, ttl)

    @impl true
    def get(key), do: get(key, &SharedInfra.RedisKV.get/1)

    @doc """
    Translate `SharedInfra.RedisKV.get/1`'s reply into THIS module's contract
    ({:ok, value} | :not_found | {:error, reason}).

    A MISSING KEY IS `:miss`, and this clause is the fix: it was absent, so an expired or unknown
    link code — the ordinary end of every 60s QR's life — fell off the case with a CaseClauseError.
    The controller's rescue caught it and answered "pending", so the browser polled a dead code
    forever instead of being told to mint a new one, and the phone's approve of an expired QR 500'd
    instead of returning its 410. `ApiGatewayWeb.NearbyBleStore` translates the same reply correctly;
    this seam was simply written against a shape RedisKV does not return.

    The unknown-reply arm returns :not_found rather than raising, ON PURPOSE: for the QR flow
    "unresolvable" degrades to "expired", which the client recovers from by minting a fresh code. It
    logs, so a future contract drift names itself instead of repeating this bug silently.

    `read` is the reader, injectable so the translation is testable without Redis.
    """
    def get(key, read) when is_function(read, 1) do
      case read.(key) do
        {:ok, value} when is_binary(value) ->
          {:ok, value}

        :miss ->
          :not_found

        {:error, reason} ->
          {:error, reason}

        other ->
          Logger.warning(
            "[link_qr] unexpected store reply, treated as not_found: #{inspect(other)}"
          )

          :not_found
      end
    end

    @impl true
    def put_get(key, value, ttl), do: SharedInfra.RedisKV.put_get(key, value, ttl)

    @impl true
    def del(key), do: SharedInfra.RedisKV.del(key)
  end
end
