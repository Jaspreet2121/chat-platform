defmodule SharedInfra.ServiceHeartbeat do
  @moduledoc """
  A liveness + build beacon for services the gateway CANNOT reach over HTTP.

  Every service with an `/internal/health` endpoint reports its own build when the admin health
  aggregator pings it. notification-service has no such endpoint — it is a pure Kafka consumer with
  no inbound port — so the aggregator hard-coded `git_sha: "unknown"` for it. That is the one service
  where a stale image is HARDEST to notice and WORST to have: pushes simply stop arriving, and
  nothing in the console says why.

  So the consumer pushes instead of being pulled. It writes `{git_sha, at}` to Redis every interval
  under a key with a TTL of several intervals, and the gateway reads it. The TTL is the whole design:
  a process that has stopped writing stops existing in Redis on its own, so "missing" and "stale"
  are the same state and neither needs a sweeper. There is no way for this to report a service as
  healthy when it is not — a dead consumer cannot refresh its own key.

  It is BEST-EFFORT in the direction that matters: a Redis failure is logged at debug and retried on
  the next tick, never crashed on. A push consumer must not die because a health beacon could not
  write. The cost of that choice is that a Redis outage shows the consumer as stale; that is the
  correct way round, because the alternative is showing it as live on no evidence.
  """
  use GenServer
  require Logger

  @default_interval_ms 30_000
  # Three missed beats before a reader calls it stale. One missed tick during a GC pause or a Redis
  # blip must not page anybody.
  @ttl_multiplier 3
  @key_prefix "service:heartbeat:"

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "The Redis key a given service beats on. Public so a human with redis-cli can find it."
  def key(service) when is_binary(service), do: @key_prefix <> service

  @doc """
  Read a service's last beat.

  `{:ok, %{git_sha: sha, at: iso8601, age_seconds: n}}` when the beacon is live, `:stale` when the
  key is absent (expired, never written, or Redis is unreachable — all of which mean the same thing
  to a reader: nobody can vouch for that process right now).
  """
  def read(service) when is_binary(service) do
    case SharedInfra.RedisKV.get(key(service)) do
      {:ok, payload} -> decode(payload)
      _ -> :stale
    end
  end

  @doc "Write one beat now. Exposed for tests and for a human who wants to prove the wiring."
  def beat(service, git_sha, ttl_seconds) when is_binary(service) and is_binary(git_sha) do
    payload =
      Jason.encode!(%{git_sha: git_sha, at: DateTime.utc_now() |> DateTime.to_iso8601()})

    SharedInfra.RedisKV.put(key(service), payload, ttl_seconds)
  end

  @impl true
  def init(opts) do
    service = Keyword.fetch!(opts, :service)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    state = %{
      service: service,
      interval_ms: interval_ms,
      ttl_seconds: Keyword.get(opts, :ttl_seconds, ttl_for(interval_ms))
    }

    # Beat immediately rather than after one interval: a container that has just come up should show
    # its new build in the console now, which is exactly when somebody is watching a deploy.
    send(self(), :beat)
    {:ok, state}
  end

  @impl true
  def handle_info(:beat, state) do
    case beat(state.service, SharedInfra.BuildInfo.git_sha(), state.ttl_seconds) do
      :ok ->
        :ok

      other ->
        Logger.debug("service heartbeat: #{state.service} write failed — #{inspect(other)}")
    end

    Process.send_after(self(), :beat, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp ttl_for(interval_ms), do: max(div(interval_ms, 1000), 1) * @ttl_multiplier

  defp decode(payload) do
    with {:ok, %{"git_sha" => sha, "at" => at}} <- Jason.decode(payload),
         {:ok, beat_at, _} <- DateTime.from_iso8601(at) do
      {:ok,
       %{
         git_sha: sha,
         at: at,
         age_seconds: DateTime.diff(DateTime.utc_now(), beat_at)
       }}
    else
      # A payload we cannot read is not evidence of anything. Same answer as no payload at all.
      _ -> :stale
    end
  end
end
