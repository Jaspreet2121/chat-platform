defmodule NotificationService.FcmSender do
  @moduledoc """
  The FCM SENDER leg (Phase 2, Android) — a PARALLEL transport beside `NotificationService.PushSender`,
  not a replacement. Both fire for the same event: a recipient may have browsers, handsets, or both,
  and each leg reads its own device table and prunes its own dead devices.

  Same rules as the web leg, deliberately: fire-and-forget per recipient OUTSIDE the fan-out
  transaction; the presence gates (`app_present?` / `present?`) with their FAIL-OPEN behaviour on any
  Redis miss; the same mute check; and the same preview text — the last three all come from
  `NotificationService.PushContext`, which exists so the two transports cannot say different things
  about the same message.

  ## DATA-ONLY, and why it matters

  Every message is sent as an FCM **`data`** payload with NO `notification` block. That is a privacy
  requirement, not a style choice: with a `notification` block FCM itself renders the alert while the
  app is backgrounded, and the client gets no say. The Android client hides message content for
  LOCKED chats, so it must be the one that decides what (if anything) is drawn. A `notification`
  payload would leak the preview of a locked conversation onto the lockscreen.

  ## Credentials

  Google service-account JSON, configured at runtime (never committed) — see `config/runtime.exs`:

      FCM_PROJECT_ID              the Firebase project id
      FCM_SERVICE_ACCOUNT_JSON    the service-account JSON *contents*, or
      FCM_SERVICE_ACCOUNT_PATH    a path to the JSON file (JSON wins if both are set)

  Unconfigured → the leg is disabled cleanly and logs once per attempt at debug, exactly like the web
  leg's `vapid_configured?`. Registration still works; nothing sends.

  Auth is an OAuth2 JWT-bearer exchange (RFC 7523) minted here with `:jose` and cached in
  `:persistent_term` until shortly before expiry — no `goth` dependency and no extra supervision tree
  for what is one signed assertion an hour.
  """

  require Logger

  alias NotificationService.PushContext
  alias NotificationService.Repo

  @token_cache_key {__MODULE__, :access_token}
  @token_scope "https://www.googleapis.com/auth/firebase.messaging"
  @token_endpoint "https://oauth2.googleapis.com/token"
  @token_ttl_seconds 3600
  # Refresh this far before the real expiry so a token never dies mid-flight.
  @token_refresh_margin_seconds 300

  @doc "Fire-and-forget FCM fan-out for an applied message_created event."
  def push_message_created(attrs, recipients) do
    if configured?() and recipients != [] do
      Task.start(fn -> deliver(attrs, recipients) end)
    end

    :ok
  end

  @doc """
  Fire-and-forget incoming-call data push for a BACKGROUNDED callee. `attrs` is the decoded
  `call.incoming` event (string keys), the same shape the web leg takes. Suppressed when the callee's
  app is foreground — they already got the in-app ring over the socket.
  """
  def push_incoming_call(attrs) when is_map(attrs) do
    callee_id = attrs["callee_id"]

    if configured?() and is_binary(callee_id) and callee_id != "" do
      Task.start(fn -> deliver_call(attrs, callee_id) end)
    end

    :ok
  end

  @doc """
  Fire-and-forget STOP-RINGING data push (2026-08-17): the decoded `call.cancelled` event (caller
  cancelled while ringing, or the server ring-timeout fired). The handset ringing off a call.incoming
  push has no socket — this is the only way the ring stops before the OS gives up.
  """
  def push_call_cancelled(attrs) when is_map(attrs) do
    callee_id = attrs["callee_id"]

    if configured?() and is_binary(callee_id) and callee_id != "" do
      Task.start(fn -> deliver_call_cancelled(attrs, callee_id) end)
    end

    :ok
  end

  # ---- Delivery ----

  @doc false
  # The SYNCHRONOUS core, wrapped in Task.start by the public API above. Public so tests can drive
  # delivery deterministically instead of racing a spawned task.
  def deliver(attrs, recipients) do
    # :no_preview = the message could not be read (absent, deleted, or a failed store read — see
    # PushContext, which logs which). Send nothing rather than an Android push whose body says
    # "New message". Must match the web leg exactly; the two must never tell one account
    # different stories on two devices.
    case PushContext.message_context(attrs) do
      :no_preview -> :ok
      {:ok, context} -> deliver_to_recipients(context, attrs, recipients)
    end
  rescue
    error -> Logger.warning("fcm deliver raised, ignored: #{inspect(error)}")
  end

  defp deliver_to_recipients(context, attrs, recipients) do
    for recipient <- recipients,
        not PushContext.muted?(attrs.conversation_id, recipient),
        # The SAME gates as the web leg, including FAIL-OPEN: a Redis miss reads as "not present"
        # and we SEND. A redundant push beats a missed one.
        not presence().app_present?(recipient),
        not presence().present?(recipient, attrs.conversation_id) do
      unread = PushContext.unread_count(attrs.conversation_id, recipient)
      data = message_data(context, attrs, unread)

      for token <- tokens_for(recipient), do: send_one(token, data)
    end
  end

  @doc false
  def deliver_call(attrs, callee_id) do
    unless presence().app_present?(callee_id) do
      data = call_data(attrs)

      # collapse_key ties the ring and its stop together: a later call.cancelled push with the SAME key
      # supersedes a still-pending incoming push where the transport supports it.
      for token <- tokens_for(callee_id),
          do: send_one(token, data, %{"collapse_key" => collapse_key(attrs)})
    end
  rescue
    error -> Logger.warning("fcm call deliver raised, ignored: #{inspect(error)}")
  end

  @doc false
  # NO presence suppression, unlike the incoming leg: if the incoming push escaped to the handset, the
  # stop must escape too — and a redundant stop is an idempotent no-op on the client (vc8), while a
  # suppressed one leaves a dead call ringing for a minute (observed on MIUI, 2026-08-16). TTL 60s: a
  # late cancel is useless — expire it rather than queue it for hours.
  def deliver_call_cancelled(attrs, callee_id) do
    data = call_cancelled_data(attrs)
    android = %{"ttl" => "60s", "collapse_key" => collapse_key(attrs)}
    for token <- tokens_for(callee_id), do: send_one(token, data, android)
  rescue
    error -> Logger.warning("fcm cancel deliver raised, ignored: #{inspect(error)}")
  end

  defp collapse_key(attrs), do: "call_" <> to_string(attrs["call_id"])

  # ---- Payloads (DATA ONLY — see the moduledoc) ----

  @doc false
  # FCM requires every data value to be a STRING; integers must be stringified or the send 400s.
  # Public so the payload contract is asserted directly, with no database and no network.
  def message_data(context, attrs, unread) do
    %{
      "type" => "message",
      "conversation_id" => to_string(attrs.conversation_id),
      "message_id" => to_string(attrs.message_id),
      "sender_id" => to_string(attrs.sender_user_id),
      "sender_name" => context.sender,
      # The SAME preview string the web leg puts in the notification body (PushContext.preview/3).
      "preview" => context.preview,
      "unread_count" => to_string(unread)
    }
    |> maybe_put("group_name", context.group_name)
  end

  @doc false
  def call_data(attrs) do
    caller =
      if is_binary(attrs["caller_name"]) and attrs["caller_name"] != "",
        do: attrs["caller_name"],
        else: "Someone"

    %{
      "type" => "call",
      "call_id" => to_string(attrs["call_id"]),
      "call_type" => to_string(attrs["call_type"] || "voice"),
      "caller_id" => to_string(attrs["caller_id"] || ""),
      "caller_name" => caller
    }
    |> maybe_put("conversation_id", attrs["conversation_id"])
  end

  @doc false
  # The client's stop contract (vc8): {"type":"call_cancelled","call_id",...,"reason"} — it also
  # accepts "call.cancelled" as the type, but the underscore form is what it documents.
  def call_cancelled_data(attrs) do
    %{
      "type" => "call_cancelled",
      "call_id" => to_string(attrs["call_id"]),
      "reason" => to_string(attrs["reason"] || "cancelled")
    }
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, to_string(value))

  @doc false
  # Public for the tests: the exact HTTP v1 envelope. `android.priority: "high"` is what lets a data
  # message wake a dozing app — without it a backgrounded handset may not see a call until much later.
  # `android_extra` merges per-message AndroidConfig on top (ttl, collapse_key) without forking the
  # envelope shape.
  def build_envelope(token, data, android_extra \\ %{}) do
    %{
      "message" => %{
        "token" => token,
        "data" => data,
        "android" => Map.merge(%{"priority" => "high"}, android_extra)
      }
    }
  end

  # ---- Transport ----

  defp send_one(token, data, android_extra \\ %{}) do
    with {:ok, access_token} <- access_token(),
         {:ok, project_id} <- project_id() do
      url = "https://fcm.googleapis.com/v1/projects/#{project_id}/messages:send"

      case http().post(url, build_envelope(token, data, android_extra), access_token) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status, body: body}} ->
          handle_error(token, status, body)

        {:error, reason} ->
          Logger.warning("fcm send failed for token #{redact(token)}: #{inspect(reason)}")
      end
    else
      _ -> :ok
    end
  rescue
    error -> Logger.warning("fcm send raised for token #{redact(token)}: #{inspect(error)}")
  end

  # UNREGISTERED = the app was uninstalled or the token rotated; INVALID_ARGUMENT on a token means it
  # was never valid. Either way it will never deliver again, so drop the row rather than keep paying
  # for it — the token twin of the web leg's 404/410 pruning.
  defp handle_error(token, status, body) do
    if dead_token?(body) do
      prune(token)
    else
      Logger.warning("fcm rejected (#{status}) for token #{redact(token)}")
    end
  end

  # Drop the dead row so we stop paying for it — the token twin of the web leg's `prune/1`.
  defp prune(token) do
    Repo.query("DELETE FROM fcm_tokens WHERE token = $1", [token])
    :ok
  rescue
    _ -> :ok
  end

  defp dead_token?(body) do
    error_status(body) in ["UNREGISTERED", "INVALID_ARGUMENT"]
  end

  defp error_status(%{"error" => %{"status" => status}}) when is_binary(status), do: status

  defp error_status(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> error_status(decoded)
      _ -> nil
    end
  end

  defp error_status(_body), do: nil

  # Never log a whole registration token — it is a delivery credential for that handset.
  defp redact(token) when is_binary(token) and byte_size(token) > 8,
    do: binary_part(token, 0, 8) <> "…"

  defp redact(_token), do: "…"

  # Read straight from the shared Postgres through OUR OWN Repo — the same service boundary the web
  # leg uses for push_subscriptions. The auth service OWNS and writes fcm_tokens; notification_service
  # only reads it, and only deletes rows FCM has declared dead (below). It does NOT call
  # AuthService.FcmTokens: notification_service has no dependency on auth_service and must not grow one.
  defp tokens_for(user_id) do
    case Repo.query("SELECT token FROM fcm_tokens WHERE user_id = $1::text::uuid", [user_id]) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [token] -> token end)
      _ -> []
    end
  rescue
    _ -> []
  end

  # ---- OAuth2 (RFC 7523 JWT-bearer), cached ----

  defp access_token do
    case :persistent_term.get(@token_cache_key, nil) do
      {token, expires_at} when is_binary(token) ->
        fresh? = now() < expires_at - @token_refresh_margin_seconds
        if fresh?, do: {:ok, token}, else: mint_token()

      _ ->
        mint_token()
    end
  end

  defp mint_token do
    with {:ok, credentials} <- credentials(),
         {:ok, assertion} <- signed_assertion(credentials),
         {:ok, %{status: status, body: body}} when status in 200..299 <-
           http().post_form(@token_endpoint, %{
             "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
             "assertion" => assertion
           }),
         {:ok, token} <- fetch_access_token(body) do
      :persistent_term.put(@token_cache_key, {token, now() + @token_ttl_seconds})
      {:ok, token}
    else
      other ->
        Logger.warning("fcm access-token mint failed: #{inspect(other)}")
        :error
    end
  rescue
    error ->
      Logger.warning("fcm access-token mint raised: #{inspect(error)}")
      :error
  end

  defp fetch_access_token(%{"access_token" => token}) when is_binary(token), do: {:ok, token}

  defp fetch_access_token(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> fetch_access_token(decoded)
      _ -> :error
    end
  end

  defp fetch_access_token(_body), do: :error

  defp signed_assertion(%{"client_email" => email, "private_key" => key})
       when is_binary(email) and is_binary(key) do
    issued_at = now()

    claims = %{
      "iss" => email,
      "scope" => @token_scope,
      "aud" => @token_endpoint,
      "iat" => issued_at,
      "exp" => issued_at + @token_ttl_seconds
    }

    jwk = JOSE.JWK.from_pem(key)
    {_meta, assertion} = JOSE.JWT.sign(jwk, %{"alg" => "RS256"}, claims) |> JOSE.JWS.compact()
    {:ok, assertion}
  rescue
    _ -> :error
  end

  defp signed_assertion(_credentials), do: :error

  # ---- Config ----

  @doc "Whether the FCM leg has everything it needs. False → disabled cleanly, nothing sends."
  def configured? do
    case {project_id(), credentials()} do
      {{:ok, _project}, {:ok, _credentials}} ->
        true

      _ ->
        Logger.debug("fcm push disabled: project id / service-account credential not configured")
        false
    end
  end

  defp project_id do
    case config()[:project_id] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  # The service-account JSON, decoded. Accepts either the raw contents or a path — a container gets
  # the contents through a secret env var, a VM mounts the file.
  defp credentials do
    case config()[:credentials] do
      %{"client_email" => _email, "private_key" => _key} = credentials -> {:ok, credentials}
      _ -> :error
    end
  end

  defp config, do: Application.get_env(:notification_service, :fcm, [])

  # Swappable so tests assert the exact envelope without touching the network.
  defp http, do: Application.get_env(:notification_service, :fcm_http, __MODULE__.HttpClient)

  # Same idiom, for the presence gates: defaults to the real marker (so production behaviour is
  # byte-for-byte the web leg's), and lets a test assert suppression without standing up Redis.
  # The FAIL-OPEN contract lives in PresenceMarker itself and is unchanged by this indirection.
  defp presence,
    do: Application.get_env(:notification_service, :fcm_presence, SharedInfra.PresenceMarker)

  defp now, do: System.system_time(:second)

  defmodule HttpClient do
    @moduledoc """
    The real FCM/OAuth transport. Behind `:fcm_http` so tests can substitute a recorder — an FCM
    send must never be attempted from a test run.
    """

    @behaviour NotificationService.FcmSender.Http

    @impl true
    def post(url, body, access_token) do
      Req.post(url,
        json: body,
        headers: [{"authorization", "Bearer #{access_token}"}],
        receive_timeout: 10_000,
        retry: false
      )
      |> normalize()
    end

    @impl true
    def post_form(url, form) do
      Req.post(url, form: form, receive_timeout: 10_000, retry: false) |> normalize()
    end

    defp normalize({:ok, %Req.Response{status: status, body: body}}),
      do: {:ok, %{status: status, body: body}}

    defp normalize({:error, reason}), do: {:error, reason}
  end
end

defmodule NotificationService.FcmSender.Http do
  @moduledoc "Transport seam for the FCM leg — one real implementation, one test recorder."

  @callback post(url :: String.t(), body :: map(), access_token :: String.t()) ::
              {:ok, %{status: integer(), body: term()}} | {:error, term()}

  @callback post_form(url :: String.t(), form :: map()) ::
              {:ok, %{status: integer(), body: term()}} | {:error, term()}
end
