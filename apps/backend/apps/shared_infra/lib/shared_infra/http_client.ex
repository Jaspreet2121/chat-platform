defmodule SharedInfra.HttpClient do
  @moduledoc """
  Shared HTTP call helper for the service→service HTTP client adapters (e.g.
  `SharedInfra.AuthClientHttp`). All 5 adapters reuse it so failure/timeout/token handling is
  uniform.

  `post_result/4` (and `get_result/3`) build the request (base URL + path + `x-internal-token`
  header + JSON body), apply connect/receive timeouts, and:
    * on HTTP **200 + a JSON envelope** → `SharedInfra.InternalApi.decode_result/2`
      (a domain `{:ok, …}` / `{:error, domain_atom}` — passes through, shape-identical to in-process);
    * on **any transport failure** (connect refused / timeout / non-200 / non-JSON) →
      `{:error, unavailable}` (the per-service atom passed via `opts[:unavailable]`).

  HTTP client = `Req` (Finch/Mint). Replaced OTP `:httpc`, whose `:inets` ships `:http_util`
  inconsistently across builds — a fresh CI runner's OTP 27.3 `:inets` had
  `http_util_which=:non_existing`, so `:httpc.request` raised `:http_util.timestamp/0` on every
  call. `Req` carries its own pure-Elixir transport, removing that environment fragility. We pass
  `decode_body: false` so Req returns the RAW body and JSON parsing stays under our control (the
  existing `decode/3` → `decode_result/2`, preserving atom-key rehydration + `skip_atomize`).
  Timeouts default to 2s connect / 5s receive (configurable via
  `:shared_infra, :http_client_connect_timeout`/`:http_client_receive_timeout`) so a call never
  hangs the caller (e.g. the gateway request). Isolated HERE so the transport can be swapped again
  by changing only this module.
  """

  require Logger

  @default_connect_timeout 2_000
  @default_receive_timeout 5_000

  @spec post_result(String.t(), String.t(), map(), keyword()) :: term()
  def post_result(base_url, path, body, opts) do
    unavailable = Keyword.fetch!(opts, :unavailable)
    decode_opts = Keyword.get(opts, :decode, [])
    encoded = Jason.encode!(body)
    request_headers = [{"content-type", "application/json"} | headers()]
    do_request(:post, url(base_url, path), request_headers, encoded, unavailable, decode_opts)
  end

  @spec get_result(String.t(), String.t(), keyword()) :: term()
  def get_result(base_url, path, opts) do
    unavailable = Keyword.fetch!(opts, :unavailable)
    decode_opts = Keyword.get(opts, :decode, [])
    do_request(:get, url(base_url, path), headers(), nil, unavailable, decode_opts)
  end

  @doc """
  HEAD an ABSOLUTE url (e.g. a presigned object-storage URL) and return the raw status + response headers.

  Unlike `post_result/4` / `get_result/3` this is NOT an internal-service JSON call: no internal token, no
  envelope decoding. It exists so a caller can read a response header (e.g. `content-length`) and tell
  200 / 404 / transport-error apart — which is exactly what verifying a completed upload needs.
  """
  @spec head(String.t()) :: {:ok, non_neg_integer(), list()} | {:error, term()}
  def head(url) when is_binary(url), do: raw_request(:head, url)

  @doc "DELETE an ABSOLUTE url (e.g. a presigned object). Returns the raw status. See `head/1`."
  @spec delete(String.t()) :: {:ok, non_neg_integer(), list()} | {:error, term()}
  def delete(url) when is_binary(url), do: raw_request(:delete, url)

  @doc """
  Send an ABSOLUTE-url request and return the RESPONSE BODY as well as the status.

  `head/1` and `delete/1` deliberately discard the body; S3's multipart API does not let us — the
  UploadId comes back only in the CreateMultipartUpload XML, and CompleteMultipartUpload can answer
  200 with an `<Error>` document that must not be read as success. Same transport, timeouts and
  fail-shape as the other raw helpers; still no internal token and no envelope decoding.
  """
  @spec raw(atom(), String.t(), keyword()) ::
          {:ok, non_neg_integer(), list(), binary()} | {:error, term()}
  def raw(method, url, opts \\ []) when is_binary(url) do
    ensure_req_started()

    request =
      [
        method: method,
        url: url,
        decode_body: false,
        retry: false,
        connect_options: [timeout: connect_timeout()],
        receive_timeout: receive_timeout()
      ]
      |> maybe_put(:body, Keyword.get(opts, :body))
      |> maybe_put(:headers, Keyword.get(opts, :headers))

    case Req.request(request) do
      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        {:ok, status, headers, body || ""}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  catch
    kind, value -> {:error, {kind, value}}
  end

  defp maybe_put(request, _key, nil), do: request
  defp maybe_put(request, key, value), do: Keyword.put(request, key, value)

  defp raw_request(method, url) do
    ensure_req_started()

    case Req.request(
           method: method,
           url: url,
           decode_body: false,
           retry: false,
           connect_options: [timeout: connect_timeout()],
           receive_timeout: receive_timeout()
         ) do
      {:ok, %Req.Response{status: status, headers: headers}} -> {:ok, status, headers}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  catch
    kind, value -> {:error, {kind, value}}
  end

  defp do_request(method, url, headers, body, unavailable, decode_opts) do
    ensure_req_started()

    case Req.request(
           method: method,
           url: url,
           headers: headers,
           body: body,
           decode_body: false,
           retry: false,
           connect_options: [timeout: connect_timeout()],
           receive_timeout: receive_timeout()
         ) do
      {:ok, %Req.Response{status: 200, body: raw}} ->
        decode(raw, unavailable, decode_opts)

      {:ok, %Req.Response{status: status}} ->
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

  # Req's default Finch pool is started lazily under `Req.FinchSupervisor`, part of the `:req`
  # application's supervision tree. If `:req` isn't started (a fresh per-app test boot / a release
  # that didn't start it), the lazy `start_child` hits a non-existent supervisor → `exit :noproc`.
  # `ensure_all_started/1` is idempotent (no-op once started), so this guarantees the pool exists
  # before every call, across CI/local/prod alike. Layer 1 (extra_applications) covers the normal
  # boot; this is the bulletproof request-path backstop.
  defp ensure_req_started do
    Application.ensure_all_started(:req)
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
    token_header() ++ correlation_header()
  end

  defp token_header do
    case SharedInfra.InternalApi.internal_token() do
      token when is_binary(token) and token != "" -> [{"x-internal-token", token}]
      _ -> []
    end
  end

  # Propagate the caller's correlation id over the internal call (when one is set in this process's
  # Logger metadata). Omitted entirely when absent — keeps prior behavior for non-traced callers.
  defp correlation_header do
    case SharedInfra.Correlation.get() do
      id when is_binary(id) and id != "" -> [{SharedInfra.Correlation.header(), id}]
      _ -> []
    end
  end

  defp url(base_url, path), do: String.trim_trailing(base_url, "/") <> path

  defp connect_timeout do
    Application.get_env(:shared_infra, :http_client_connect_timeout, @default_connect_timeout)
  end

  defp receive_timeout do
    Application.get_env(:shared_infra, :http_client_receive_timeout, @default_receive_timeout)
  end
end
