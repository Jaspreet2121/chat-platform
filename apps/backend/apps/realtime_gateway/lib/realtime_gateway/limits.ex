defmodule RealtimeGateway.Limits do
  @moduledoc """
  Rate limiting + connection cap for `/socket`. Before this, a client could open unbounded sockets and push
  unbounded joins/messages/ephemerals. Four buckets, all per-USER and per-APP (tenant), all FAIL-OPEN:

    * connection — max concurrent sockets (RealtimeGateway.ConnectionCounter). Over → refuse `connect/3`.
    * join       — channel joins. Over → refuse the join.
    * write      — durable/fan-out events (message send/edit/delete/reaction, call control). Over → an error
                   reply WITH `retry_after`; the socket STAYS connected (the SDK backs off — see 33ef741).
    * ephemeral  — fire-and-forget (typing, receipts, live-location, app fg/bg, call signalling). Over →
                   DROP SILENTLY (a `{:noreply}`); an error reply for a dropped typing event is just noise.

  Rate buckets reuse `SharedInfra.RateLimiter` (fixed-window INCR+EXPIRE, fail-open). NOTE: a FIXED window
  has the classic boundary-burst weakness — up to 2× the limit across a window edge. Not fixed here (out of
  scope; the same weakness the /v1 REST limiter already lives with). The socket path does NOT need sliding
  more urgently than REST: both are per-(user,app) abuse guards, not exact quotas, and the connection cap
  independently bounds concurrency, so a 2× burst on one edge is not a new class of risk.

  Per-app RATE limits: the task fixes the per-USER numbers (join 30, write 60, ephemeral 300 / min); the
  per-APP ceiling is derived as per-user × RT_APP_LIMIT_FACTOR (default 100 — a tenant of ~100 active users)
  so one tenant's end-users can't collectively flood. All limits are env-configurable (see below); read at
  the CALL SITE via System.get_env — the same precedent as V1_RATE_LIMIT (which V1Runtime.limit/0 reads
  directly, NOT baked into runtime.exs), so a value change needs no redeploy of a compiled release.
  """

  alias RealtimeGateway.ConnectionCounter

  @telemetry_event [:realtime, :limit, :exceeded]

  # --- connection cap ------------------------------------------------------------------------------

  @doc """
  Admit a new socket, or refuse it over the per-user / per-app concurrent cap. Returns `{:ok, socket_ref}`
  (record the ref in socket assigns; it identifies this socket in the counter for touch/release) or `:error`.
  """
  @spec check_connection(Phoenix.Socket.t()) :: {:ok, String.t()} | :error
  def check_connection(socket) do
    now = System.system_time(:second)
    user_id = uid(socket)
    app_id = aid(socket)
    ref = new_ref()

    cond do
      ConnectionCounter.count(conn_key(:user, user_id), now) >= max_sockets_per_user() ->
        emit(:connection, :user, app_id, user_id)
        :error

      ConnectionCounter.count(conn_key(:app, app_id), now) >= max_sockets_per_app() ->
        emit(:connection, :app, app_id, user_id)
        :error

      true ->
        ConnectionCounter.touch(conn_key(:user, user_id), ref, now)
        ConnectionCounter.touch(conn_key(:app, app_id), ref, now)
        {:ok, ref}
    end
  end

  @doc "Refresh from a socket (heartbeat) — resolves user/app/ref from assigns; no-op if never admitted."
  def touch_connection(%{assigns: assigns} = socket) do
    case Map.get(assigns, :socket_ref) do
      ref when is_binary(ref) -> touch_connection(uid(socket), aid(socket), ref)
      _ -> :ok
    end
  end

  @doc "Refresh this socket's connection entry (heartbeat) so a live socket isn't aged out of the window."
  @spec touch_connection(String.t(), String.t(), String.t()) :: :ok
  def touch_connection(user_id, app_id, ref) when is_binary(ref) and ref != "" do
    now = System.system_time(:second)
    ConnectionCounter.touch(conn_key(:user, user_id), ref, now)
    ConnectionCounter.touch(conn_key(:app, app_id), ref, now)
    :ok
  end

  def touch_connection(_user_id, _app_id, _ref), do: :ok

  @doc "Release from a socket on disconnect — resolves user/app/ref from assigns; no-op if never admitted."
  def release_connection(%{assigns: assigns} = socket) do
    case Map.get(assigns, :socket_ref) do
      ref when is_binary(ref) -> release_connection(uid(socket), aid(socket), ref)
      _ -> :ok
    end
  end

  @doc "Release this socket's slot on a clean disconnect (the immediate decrement; aging is the safety net)."
  @spec release_connection(String.t(), String.t(), String.t()) :: :ok
  def release_connection(user_id, app_id, ref) when is_binary(ref) and ref != "" do
    ConnectionCounter.remove(conn_key(:user, user_id), ref)
    ConnectionCounter.remove(conn_key(:app, app_id), ref)
    :ok
  end

  def release_connection(_user_id, _app_id, _ref), do: :ok

  # --- per-bucket rate limits (returned as the exact handler result each bucket needs) -------------

  @doc "Join gate → :ok | {:error, %{reason: \"rate_limited\"}} (used in `with` before authorize_join)."
  def check_join(socket) do
    case rate_check(:join, socket) do
      :ok -> :ok
      {:limited, _retry} -> {:error, %{reason: "rate_limited"}}
    end
  end

  @doc "Write gate → :ok | a full {:reply, {:error, %{reason, retry_after}}, socket} — socket stays alive."
  def check_write(socket) do
    case rate_check(:write, socket) do
      :ok -> :ok
      {:limited, retry_after} -> {:reply, {:error, %{reason: "rate_limited", retry_after: retry_after}}, socket}
    end
  end

  @doc "Ephemeral gate → :ok | {:noreply, socket} — over limit is DROPPED SILENTLY (no error reply)."
  def check_ephemeral(socket) do
    case rate_check(:ephemeral, socket) do
      :ok -> :ok
      {:limited, _retry} -> {:noreply, socket}
    end
  end

  # Check per-user THEN per-app; the first to trip wins (emitting which scope). :ok | {:limited, retry_after}.
  defp rate_check(bucket, socket) do
    user_id = uid(socket)
    app_id = aid(socket)
    window = window_seconds()
    per_user = user_limit(bucket)

    case check_key("rt:#{bucket}:user:#{user_id}", per_user, window) do
      {:limited, retry} ->
        emit(bucket, :user, app_id, user_id)
        {:limited, retry}

      :ok ->
        case check_key("rt:#{bucket}:app:#{app_id}", per_user * app_factor(), window) do
          {:limited, retry} ->
            emit(bucket, :app, app_id, user_id)
            {:limited, retry}

          :ok ->
            :ok
        end
    end
  end

  defp check_key(key, limit, window) do
    case SharedInfra.RateLimiter.check_rate(%{
           "key" => key,
           "limit" => limit,
           "window_seconds" => window
         }) do
      :ok -> :ok
      {:error, :rate_limited, retry_after} -> {:limited, retry_after}
      # Invalid attrs / limiter unavailable → FAIL-OPEN (allow). A limiter must never take down the socket.
      _ -> :ok
    end
  end

  # --- helpers -------------------------------------------------------------------------------------

  defp conn_key(:user, user_id), do: "rt:conn:user:#{user_id}"
  defp conn_key(:app, app_id), do: "rt:conn:app:#{app_id}"

  defp uid(socket) do
    Map.get(socket.assigns, :user_id) || Map.get(socket.assigns, :current_user_id) || "unknown"
  end

  defp aid(socket), do: Map.get(socket.assigns, :app_id) || "unknown"

  defp new_ref, do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

  defp emit(bucket, scope, app_id, user_id) do
    :telemetry.execute(@telemetry_event, %{count: 1}, %{
      bucket: bucket,
      scope: scope,
      app_id: app_id,
      user_id: user_id
    })
  rescue
    _ -> :ok
  end

  # --- config (read at the call site via env — the V1_RATE_LIMIT precedent; never compile-baked) ---

  # A later apps.plan column can make the per-app caps tier-based; for now a single default each.
  defp max_sockets_per_user, do: env_int("RT_MAX_SOCKETS_PER_USER", 5)
  defp max_sockets_per_app, do: env_int("RT_MAX_SOCKETS_PER_APP", 1000)
  defp window_seconds, do: env_int("RT_WINDOW_SECONDS", 60)
  defp app_factor, do: env_int("RT_APP_LIMIT_FACTOR", 100)

  defp user_limit(:join), do: env_int("RT_JOIN_LIMIT", 30)
  defp user_limit(:write), do: env_int("RT_WRITE_LIMIT", 60)
  defp user_limit(:ephemeral), do: env_int("RT_EPHEMERAL_LIMIT", 300)

  defp env_int(name, default) do
    case System.get_env(name) do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, _} when n > 0 -> n
          _ -> default
        end

      _ ->
        default
    end
  end
end
