defmodule SharedInfra.Kafka.ConsumerGroups do
  @moduledoc """
  THE ONE LIST of every Kafka consumer group this platform runs, and the only place a new one is
  registered.

  Each entry is a group id, the topic it consumes, and which service owns it. That is all. In
  particular it does NOT record how many partitions a topic has, and it does NOT record whether a
  group is currently switched on.

  ## Why those two are deliberately absent

  **Partition counts are read live from Kafka.** They are a property of the topic, declared in
  `infra/docker/kafka/topics.env` and changeable without touching Elixir, so a copy here would be a
  second source of truth that silently goes stale. A copy would also have been WRONG on the day this
  was written: the counts quoted from a production describe (7, 4, 4 for the notification groups)
  disagree with `topics.env` (6, 3, 3 for the topics they read). Reading them means the monitor
  reports whatever is actually there and the disagreement shows up as data rather than as an
  argument settled in a comment.

  **"Deliberately off" is read live too, as a group with ZERO members.** Four of these seven groups
  are switched off today, each behind its own env var on its own container
  (`KAFKA_PROJECTION_CONSUMER_ENABLED` and friends). Copying that state here would mean turning a
  consumer on required a code change in two places — the env var AND this file — which is exactly
  the drift the caller asked to avoid. A group nobody has joined has no members, is reported `off`,
  and never alarms. Set its env var, restart that container, and it joins, gains members, and starts
  being watched. No code change anywhere.

  So the ONLY thing that belongs in this list is the existence of a group. Add one here when you
  create it, and it is monitored from its first poll whether or not it is switched on yet.
  """

  @groups [
    %{
      group_id: "message-service-inbox-projection",
      topic: "message.events.v1",
      service: "message"
    },
    %{group_id: "message-service-search-index", topic: "message.events.v1", service: "message"},
    %{
      group_id: "message-service-conversation-summary",
      topic: "message.events.v1",
      service: "message"
    },
    %{group_id: "message-service-log-consumer", topic: "message.events.v1", service: "message"},
    %{
      group_id: "notification-service-message-created",
      topic: "message.events.v1",
      service: "notification"
    },
    %{
      group_id: "notification-service-conversation-participants",
      topic: "conversation.events.v1",
      service: "notification"
    },
    %{
      group_id: "notification-service-call-incoming",
      topic: "call.events.v1",
      service: "notification"
    }
  ]

  @doc "Every registered consumer group."
  def all, do: @groups

  @doc "The distinct topics any registered group reads — what the monitor needs partition counts for."
  def topics, do: @groups |> Enum.map(& &1.topic) |> Enum.uniq()

  @doc "The group ids, in registration order."
  def ids, do: Enum.map(@groups, & &1.group_id)
end
