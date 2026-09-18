defmodule MessageService.Kafka.LagMonitor do
  @moduledoc """
  THE CONSUMER-LAG ALARM. Polls every registered consumer group's lag on a timer, logs at WARN when
  one is behind or stalled, and keeps the last snapshot so `/internal/health` — and through it
  `/admin/health` — can answer "is anything behind?" with one curl.

  Before this, nothing noticed a stalled group. It was found by running the describe command by hand,
  which means it was found when somebody thought to look.

  This deployment is a single box running docker compose with no Prometheus, so the cheapest thing
  that actually works is a GenServer in a service that already talks to Kafka. Lag is read from the
  CLUSTER, not from the consuming process, so this one monitor covers notification-service's groups
  as well as message-service's own without either service knowing about the other.

  ## Two alarms, because one of them is not enough

  **BEHIND** — total lag over the threshold. Catches a group that is falling behind under load.

  **STALLED** — lag above zero and the committed offset has not moved since the previous poll.
  Catches a group that has stopped dead, at ANY traffic level, within two intervals. The threshold
  alarm alone cannot do this: a group that stalls on a quiet afternoon accumulates lag at whatever
  rate the platform is producing, so at ten messages a minute it would take an hour and a half to
  cross a threshold set where bursts do not trip it. A stopped consumer is the failure this exists
  for, and it should not take ninety minutes to say so.

  ## The threshold, and where the numbers live

  The threshold is justified against real traffic beside its definition below. Everything else this
  monitor needs is read from Kafka rather than written down: partition counts come from topic
  metadata, and whether a group is switched on comes from whether anyone has joined it. The only
  static list is `SharedInfra.Kafka.ConsumerGroups`, which records that a group exists and nothing
  else, so turning a consumer on is one env var on one container and no code change at all.
  """

  use GenServer
  require Logger

  alias SharedInfra.Kafka.ConsumerGroups
  alias SharedInfra.Kafka.LagReader

  # THE THRESHOLD, against what real traffic produces. One message is one `message.created.v1`, so
  # "lag" counts messages the platform has accepted but a group has not processed.
  #
  #   * one account is capped at 60 sends a minute (the REST limiter and the socket write bucket
  #     agree, deliberately, so the cap is not bypassable by transport);
  #   * the largest single fan-out is a broadcast: 256 recipients, one event each, produced about as
  #     fast as the gateway can loop — the biggest legitimate instantaneous spike in the system;
  #   * the broadcast limiter caps that at 20 sends an hour, so ~5,120 events an hour at the ceiling.
  #
  # 1,000 sits above every one of those: four full broadcast fan-outs, or sixteen minutes of a single
  # account sending flat out at its cap. A healthy consumer drains a spike of that size inside one
  # poll interval, so this cannot be reached by legitimate traffic that is being kept up with. It is
  # a "falling behind" number, not a "stopped" number — stopping is what the stall check is for.
  @default_threshold 1_000
  @default_interval_ms 60_000

  # A snapshot older than this is not served as current. Three intervals, so one slow or failed poll
  # does not flip the health endpoint to stale, but a monitor that has actually stopped does.
  @stale_after_intervals 3

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The last snapshot, with its age. `checked_at` and `stale` are part of the payload on purpose: a
  monitoring endpoint that serves a cached number without saying how old it is turns a dead monitor
  into a permanently green dashboard, which is worse than having no endpoint at all.
  """
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot, 5_000)
  catch
    :exit, _ -> %{status: "unavailable", groups: [], checked_at: nil, stale: true}
  end

  @doc "Force a poll now and return the fresh snapshot. For tests and for a human with a shell."
  def poll_now(server \\ __MODULE__) do
    GenServer.call(server, :poll_now, 30_000)
  end

  @impl true
  def init(opts) do
    state = %{
      endpoints: Keyword.get(opts, :endpoints, []),
      threshold: Keyword.get(opts, :threshold, configured_threshold()),
      interval_ms: Keyword.get(opts, :interval_ms, configured_interval()),
      previous: %{},
      snapshot: nil,
      checked_at: nil
    }

    state =
      Map.put(
        state,
        :stale_after_seconds,
        Keyword.get(
          opts,
          :stale_after_seconds,
          @stale_after_intervals * max(div(state.interval_ms, 1000), 1)
        )
      )

    if Keyword.get(opts, :poll_on_start, true), do: send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = run_poll(state)
    Process.send_after(self(), :poll, state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, render(state), state}

  @impl true
  def handle_call(:poll_now, _from, state) do
    state = run_poll(state)
    {:reply, render(state), state}
  end

  defp run_poll(state) do
    groups = ConsumerGroups.all()
    members = member_counts(state.endpoints, Enum.map(groups, & &1.group_id))
    latest = latest_by_topic(state.endpoints, ConsumerGroups.topics())

    rows = Enum.map(groups, &measure(&1, state, members, latest))
    Enum.each(rows, &alarm(&1, state.threshold))

    %{
      state
      | snapshot: rows,
        checked_at: DateTime.utc_now(),
        previous: Map.new(rows, fn row -> {row.group_id, {row.committed_total, row.status}} end)
    }
  end

  defp measure(%{group_id: group_id, topic: topic} = group, state, members, latest) do
    member_count = Map.get(members, group_id, 0)
    base = %{group_id: group_id, topic: topic, service: group.service, members: member_count}

    cond do
      # DELIBERATELY OFF. A group nobody has joined has no members. Four of the seven are switched
      # off today, each behind its own env var on its own container, and none of them must ever
      # alarm — a 0/6 group is a decision, not an incident. There is no list of "off" groups here to
      # keep in step with those env vars: this IS the answer to whether one is running.
      member_count == 0 ->
        Map.merge(base, %{status: "off", lag: nil, committed_total: nil, partitions: 0})

      true ->
        case LagReader.committed_offsets(state.endpoints, group_id) do
          {:ok, committed} ->
            lag_for(base, committed, Map.get(latest, topic, %{}), topic, state)

          {:error, reason} ->
            Map.merge(base, %{
              status: "unknown",
              lag: nil,
              committed_total: nil,
              partitions: 0,
              error: inspect(reason)
            })
        end
    end
  end

  defp lag_for(base, committed, latest, topic, state) do
    pairs =
      for {partition, end_offset} <- latest,
          is_integer(end_offset),
          do: {partition, end_offset - Map.get(committed, {topic, partition}, end_offset)}

    lag = pairs |> Enum.map(&elem(&1, 1)) |> Enum.sum() |> max(0)

    committed_total =
      committed
      |> Enum.filter(fn {{t, _p}, _o} -> t == topic end)
      |> Enum.map(fn {_k, offset} -> offset end)
      |> Enum.sum()

    {previous_committed, _} = Map.get(state.previous, base.group_id, {nil, nil})

    status =
      cond do
        lag > state.threshold -> "behind"
        lag > 0 and previous_committed == committed_total -> "stalled"
        true -> "ok"
      end

    Map.merge(base, %{
      status: status,
      lag: lag,
      committed_total: committed_total,
      partitions: map_size(latest)
    })
  end

  defp alarm(%{status: "behind"} = row, threshold) do
    Logger.warning(
      "kafka consumer lag: group=#{row.group_id} BEHIND lag=#{row.lag} threshold=#{threshold} " <>
        "topic=#{row.topic} members=#{row.members}"
    )
  end

  defp alarm(%{status: "stalled"} = row, _threshold) do
    Logger.warning(
      "kafka consumer lag: group=#{row.group_id} STALLED lag=#{row.lag} " <>
        "(committed offset unchanged since the previous poll) topic=#{row.topic} " <>
        "members=#{row.members}"
    )
  end

  defp alarm(%{status: "unknown"} = row, _threshold) do
    Logger.warning(
      "kafka consumer lag: group=#{row.group_id} UNREADABLE — #{Map.get(row, :error)}. " <>
        "This is the monitor failing, not the group; lag is unknown, not zero."
    )
  end

  # "off" and "ok" are silent. A deliberately-disabled group logging every minute is how an alarm
  # becomes noise and then becomes ignored.
  defp alarm(_row, _threshold), do: :ok

  defp member_counts(endpoints, group_ids) do
    case LagReader.member_counts(endpoints, group_ids) do
      {:ok, counts} ->
        counts

      {:error, reason} ->
        Logger.warning("kafka consumer lag: describe failed — #{inspect(reason)}")
        %{}
    end
  end

  defp latest_by_topic(endpoints, topics) do
    Map.new(topics, fn topic ->
      case LagReader.latest_offsets(endpoints, topic) do
        {:ok, offsets} -> {topic, offsets}
        {:error, _reason} -> {topic, %{}}
      end
    end)
  end

  defp render(%{snapshot: nil}),
    do: %{status: "unavailable", groups: [], checked_at: nil, stale: true, age_seconds: nil}

  defp render(state) do
    age = DateTime.diff(DateTime.utc_now(), state.checked_at)
    stale = age > state.stale_after_seconds

    %{
      # The WORST status across the groups, so one field answers the question. A stale snapshot is
      # reported as stale whatever it contains — numbers nobody has refreshed are not "ok".
      status: if(stale, do: "stale", else: worst(state.snapshot)),
      stale: stale,
      age_seconds: age,
      checked_at: DateTime.to_iso8601(state.checked_at),
      threshold: state.threshold,
      groups: state.snapshot
    }
  end

  defp worst(rows) do
    cond do
      Enum.any?(rows, &(&1.status == "stalled")) -> "stalled"
      Enum.any?(rows, &(&1.status == "behind")) -> "behind"
      Enum.any?(rows, &(&1.status == "unknown")) -> "unknown"
      true -> "ok"
    end
  end

  defp configured_threshold do
    case System.get_env("KAFKA_LAG_WARN_THRESHOLD") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {n, ""} when n > 0 -> n
          _ -> @default_threshold
        end

      _ ->
        Application.get_env(:message_service, :kafka_lag_threshold, @default_threshold)
    end
  end

  defp configured_interval do
    Application.get_env(:message_service, :kafka_lag_interval_ms, @default_interval_ms)
  end
end
