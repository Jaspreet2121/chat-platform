defmodule SharedInfra.Kafka.LagReader do
  @moduledoc """
  The three Kafka reads consumer lag needs, behind a behaviour so the monitor above it can be driven
  deterministically without a broker.

  Lag is (log end offset) minus (committed offset), summed over a group's partitions. That needs:

    * how many MEMBERS a group has, which is how "deliberately off" is told from "stalled" — a group
      nobody joined has none;
    * what each partition's COMMITTED offset is, which is how far the group has got;
    * what each partition's LATEST offset is, which is how far the topic has got.

  All three are read from Kafka itself, never from the consuming process, so one service can report
  on groups that live in another container. That is what lets message-service answer for
  notification-service's three groups without either knowing about the other.
  """

  @type endpoints :: [{charlist(), non_neg_integer()}]

  @callback member_counts(endpoints(), [String.t()]) ::
              {:ok, %{String.t() => non_neg_integer()}} | {:error, term()}
  @callback committed_offsets(endpoints(), String.t()) ::
              {:ok, %{{String.t(), non_neg_integer()} => integer()}} | {:error, term()}
  @callback latest_offsets(endpoints(), String.t()) ::
              {:ok, %{non_neg_integer() => integer()}} | {:error, term()}

  def adapter do
    Application.get_env(:shared_infra, :kafka_lag_reader, SharedInfra.Kafka.LagReader.Brod)
  end

  def member_counts(endpoints, group_ids), do: adapter().member_counts(endpoints, group_ids)
  def committed_offsets(endpoints, group_id), do: adapter().committed_offsets(endpoints, group_id)
  def latest_offsets(endpoints, topic), do: adapter().latest_offsets(endpoints, topic)
end

defmodule SharedInfra.Kafka.LagReader.Brod do
  @moduledoc """
  The real reader. Every call is a short-lived connection to the cluster, which is the right shape
  here: this runs once a minute, not per request, and a long-lived client for it would be one more
  thing to supervise for no gain.

  Every function returns `{:error, reason}` rather than raising. A broker that cannot be reached is a
  fact the monitor reports, not a crash it propagates into a supervision tree.
  """
  @behaviour SharedInfra.Kafka.LagReader

  @conn_config []

  @impl true
  def member_counts(endpoints, group_ids) do
    # describe_groups talks to the group COORDINATOR, so it takes one endpoint rather than the list.
    case endpoints do
      [coordinator | _] ->
        case :brod.describe_groups(coordinator, @conn_config, group_ids) do
          {:ok, described} -> {:ok, Map.new(described, &describe_entry/1)}
          {:error, reason} -> {:error, reason}
        end

      [] ->
        {:error, :no_endpoints}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @impl true
  def committed_offsets(endpoints, group_id) do
    case :brod.fetch_committed_offsets(endpoints, @conn_config, group_id) do
      {:ok, responses} ->
        {:ok,
         for(
           %{name: topic, partitions: partitions} <- Enum.map(responses, &normalise/1),
           %{partition_index: partition, committed_offset: offset} <-
             Enum.map(partitions, &normalise/1),
           # -1 is Kafka for "this group has never committed here". Not a zero-offset commit, and
           # counting it as one would report an entire topic's backlog as lag on a group that has
           # simply never run.
           offset >= 0,
           into: %{},
           do: {{to_string(topic), partition}, offset}
         )}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @impl true
  def latest_offsets(endpoints, topic) do
    with {:ok, count} <- partition_count(endpoints, topic) do
      offsets =
        for partition <- 0..(count - 1)//1, into: %{} do
          case :brod.resolve_offset(endpoints, topic, partition, :latest) do
            {:ok, offset} -> {partition, offset}
            _ -> {partition, nil}
          end
        end

      {:ok, offsets}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # Partition count comes from topic METADATA, not from a hardcoded table: it is a property of the
  # topic that `infra/docker/kafka/topics.env` can change without touching Elixir.
  defp partition_count(endpoints, topic) do
    case :brod.get_metadata(endpoints, [topic]) do
      {:ok, metadata} ->
        topics = metadata |> normalise() |> Map.get(:topics, [])

        case Enum.find(topics, fn t -> to_string(normalise(t)[:name]) == topic end) do
          nil -> {:error, :unknown_topic}
          found -> {:ok, length(normalise(found)[:partitions] || [])}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp describe_entry(group) do
    group = normalise(group)
    id = to_string(group[:group_id] || group[:groupId] || "")
    {id, length(group[:members] || [])}
  end

  # kpro structs arrive as maps with atom keys; be tolerant of a list-of-pairs shape too so a
  # kafka_protocol change cannot turn a monitoring read into a crash.
  defp normalise(value) when is_map(value), do: value
  defp normalise(value) when is_list(value), do: Map.new(value)
  defp normalise(value), do: %{value: value}
end
