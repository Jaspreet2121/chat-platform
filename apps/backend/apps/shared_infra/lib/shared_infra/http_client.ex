defmodule SharedInfra.HttpClient do
  @moduledoc """
  Shared HTTP call helper for the service→service HTTP client adapters (e.g.
  `SharedInfra.AuthClientHttp`). All 5 adapters reuse it so failure/timeout/token handling is
  uniform.

  `post_result/4` (and `get_result/3`) build the request (base URL + path + `x-internal-token`
  header + JSON body), apply connect/receive timeouts, and:
    * on HTTP **200 + a JSON envelope** → `SharedInfra.InternalApi.decode_result/1`
      (a domain `{:ok, …}` / `{:error, domain_atom}` — passes through, shape-identical to in-process);
    * on **any transport failure** (connect refused / timeout / non-200 / non-JSON) →
      `{:error, unavailable}` (the per-service atom passed via `opts[:unavailable]`).

  HTTP client = OTP's `:httpc` (`:inets`) — zero new deps, chosen because the package registry is
  unreachable in this environment (Req couldn't be fetched). Isolated HERE so it can be swapped for
  Req later by changing only this module. Timeouts default to 2s connect / 5s receive (configurable
  via `:shared_infra, :http_client_connect_timeout`/`:http_client_receive_timeout`) so a call never
  hangs the caller (e.g. the gateway request).
  """

  require Logger

  @default_connect_timeout 2_000
  @default_receive_timeout 5_000

  @spec post_result(String.t(), String.t(), map(), keyword()) :: term()
  def post_result(base_url, path, body, opts) do
    unavailable = Keyword.fetch!(opts, :unavailable)
    decode_opts = Keyword.get(opts, :decode, [])
    encoded = Jason.encode!(body)
    request = {url(base_url, path), headers(), ~c"application/json", encoded}
    do_request(:post, request, unavailable, decode_opts)
  end

  @spec get_result(String.t(), String.t(), keyword()) :: term()
  def get_result(base_url, path, opts) do
    unavailable = Keyword.fetch!(opts, :unavailable)
    decode_opts = Keyword.get(opts, :decode, [])
    do_request(:get, {url(base_url, path), headers()}, unavailable, decode_opts)
  end

  defp do_request(method, request, unavailable, decode_opts) do
    ensure_inets_started()
    http_opts = [connect_timeout: connect_timeout(), timeout: receive_timeout()]

    case :httpc.request(method, request, http_opts, body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, body}} ->
        decode(body, unavailable, decode_opts)

      {:ok, {{_version, status, _reason}, _headers, _body}} ->
        Logger.warning("internal HTTP call #{inspect(method)} returned status #{status}")
        {:error, unavailable}

      {:error, reason} ->
        Logger.warning("internal HTTP call #{inspect(method)} failed: #{inspect(reason)}")
        {:error, unavailable}
    end
  rescue
    error ->
      Logger.warning("internal HTTP call raised: #{inspect(error)}")
      {:error, unavailable}
  catch
    kind, value ->
      Logger.warning("internal HTTP call #{kind}: #{inspect(value)}")
      {:error, unavailable}
  end

  # `:httpc` lives in OTP's `:inets`; calling it before `:inets` is started raises
  # `:http_util.timestamp/0` UndefinedFunctionError (which the rescue above would otherwise turn
  # into a spurious `:*_unavailable`). `extra_applications: [:inets, :ssl]` in mix.exs does NOT
  # reliably cover every test/release boot path (a fresh CI runner exposed this), so we guarantee
  # it here in the request path. `ensure_all_started/1` is idempotent — a no-op once started — so
  # the per-call cost is negligible. `:ssl` is included for any https base URL.
  defp ensure_inets_started do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)
    :ok
  end

  defp decode(body, unavailable, decode_opts) do
    case Jason.decode(body) do
      {:ok, envelope} when is_map(envelope) ->
        SharedInfra.InternalApi.decode_result(envelope, decode_opts)

      _ ->
        {:error, unavailable}
    end
  end

  defp headers do
    case SharedInfra.InternalApi.internal_token() do
      token when is_binary(token) and token != "" -> [{~c"x-internal-token", to_charlist(token)}]
      _ -> []
    end
  end

  defp url(base_url, path), do: String.to_charlist(String.trim_trailing(base_url, "/") <> path)

  defp connect_timeout do
    Application.get_env(:shared_infra, :http_client_connect_timeout, @default_connect_timeout)
  end

  defp receive_timeout do
    Application.get_env(:shared_infra, :http_client_receive_timeout, @default_receive_timeout)
  end
end
