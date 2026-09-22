defmodule NotificationService.ApnsHttp do
  @moduledoc """
  The HTTP/2 transport for `NotificationService.ApnsSender`, behind a one-function behaviour so the
  sender's payload and header shaping — the part that actually goes wrong — is testable with no
  network.

  ## HTTP/2 is not optional here

  APNs speaks HTTP/2 only; it will not answer an HTTP/1.1 request at all. Finch is already in the
  tree through `:req` and negotiates h2 over ALPN, but its DEFAULT pool does not ask for it, so this
  starts a named pool that does. That pool is also what keeps the TLS handshake off the per-push
  path: a fan-out to a group opens one connection, not one per recipient.

  ## Started only when Apple is configured

  No key, no pool. A deployment without an Apple key must not hold idle TLS connections to Apple, and
  `child_spec/0` returning `[]` is what keeps the supervision tree identical to what it was.
  """

  @behaviour NotificationService.ApnsTransport

  @name __MODULE__.Pool

  @doc """
  The Finch child for the supervision tree, or `[]` when APNs is not configured.

  Both hosts are declared: a device token is valid at exactly one of them and which one is a property
  of the token, so a deployment that has any iOS users at all will generally use both.
  """
  def child_spec do
    if SharedInfra.Apns.ProviderToken.configured?() do
      [
        {Finch,
         name: @name,
         pools: %{
           "https://api.push.apple.com" => [protocols: [:http2], count: 1],
           "https://api.sandbox.push.apple.com" => [protocols: [:http2], count: 1]
         }}
      ]
    else
      []
    end
  end

  @impl true
  def post(url, headers, body) do
    :post
    |> Finch.build(url, headers, body)
    |> Finch.request(@name, receive_timeout: 10_000)
    |> case do
      {:ok, %Finch.Response{status: status, body: response_body}} -> {:ok, status, response_body}
      {:error, reason} -> {:error, reason}
    end
  rescue
    # A pool that was never started (no key at boot, a key added since) raises rather than returning
    # an error. That is a configuration fault, not a push failure, and the sender logs it as one.
    error -> {:error, error}
  end
end

defmodule NotificationService.ApnsTransport do
  @moduledoc """
  One call: POST this body to this URL with these headers, tell me the status and the body.

  Deliberately this small. Everything interesting about an APNs push — the topic, the push type, the
  priority, the provider token, which host — is a HEADER or a URL the sender builds, so a test that
  captures those three arguments is testing the whole contract.
  """
  @callback post(url :: String.t(), headers :: [{String.t(), String.t()}], body :: String.t()) ::
              {:ok, non_neg_integer(), String.t()} | {:error, term()}
end
