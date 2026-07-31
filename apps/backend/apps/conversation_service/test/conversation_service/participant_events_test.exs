defmodule ConversationService.ParticipantEventsTest do
  @moduledoc """
  Proves the fire-and-forget participant-change emission contract WITHOUT a live broker
  (a fake in-process producer adapter). Docker-free, plain tests — exercises the
  `ParticipantEvents` helpers directly (no Repo). The emit-after-persist WIRING through the
  create/add/remove boundaries is covered by the postgres_integration tests.
  """
  use ExUnit.Case, async: false

  alias ConversationService.ParticipantEvents

  @topic "conversation.events.v1"

  setup do
    previous = %{
      publish: Application.get_env(:conversation_service, :conversation_publish_enabled, false),
      producer: Application.get_env(:shared_infra, :kafka_producer_adapter)
    }

    Application.put_env(:shared_infra, :capture_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:shared_infra, :capture_test_pid)
      Application.put_env(:conversation_service, :conversation_publish_enabled, previous.publish)

      if previous.producer do
        Application.put_env(:shared_infra, :kafka_producer_adapter, previous.producer)
      else
        Application.delete_env(:shared_infra, :kafka_producer_adapter)
      end
    end)

    :ok
  end

  defp enable_capture! do
    Application.put_env(:conversation_service, :conversation_publish_enabled, true)

    Application.put_env(
      :shared_infra,
      :kafka_producer_adapter,
      ConversationService.CaptureKafkaProducer
    )
  end

  test "publish_initial_participants emits one participant_added per participant (owner + members)" do
    enable_capture!()

    conversation_id = unique_id()
    creator = unique_id()
    member1 = unique_id()
    member2 = unique_id()

    assert :ok =
             ParticipantEvents.publish_initial_participants(
               conversation_id,
               creator,
               [creator, member1, member2]
             )

    # Collect all three emitted envelopes by user_id.
    {payloads, one_env} = collect_added(conversation_id, 3)

    # Roles: owner for the creator, member for the rest; added_by is the creator.
    assert payloads[creator]["role"] == "owner"
    assert payloads[member1]["role"] == "member"
    assert payloads[member2]["role"] == "member"

    for {_uid, payload} <- payloads do
      assert payload["conversation_id"] == conversation_id
      assert payload["added_by"] == creator
    end

    # The envelopes are valid per the standard contract.
    assert one_env.event_type == "conversation.participant_added.v1"
    assert one_env.producer == "conversation-service"
    assert one_env.event_version == 1
    assert {:ok, _} = SharedInfra.Events.Envelope.validate(one_env)
  end

  test "publish_participant_added emits the exact contract payload" do
    enable_capture!()

    conversation_id = unique_id()
    user_id = unique_id()
    actor = unique_id()

    assert :ok =
             ParticipantEvents.publish_participant_added(%{
               conversation_id: conversation_id,
               user_id: user_id,
               role: "member",
               added_by: actor
             })

    assert_receive {:kafka_published, @topic, ^conversation_id, env}, 1_000
    assert env.event_type == "conversation.participant_added.v1"

    assert env.payload == %{
             "conversation_id" => conversation_id,
             "user_id" => user_id,
             "role" => "member",
             "added_by" => actor
           }
  end

  test "publish_participant_removed emits the exact contract payload" do
    enable_capture!()

    conversation_id = unique_id()
    user_id = unique_id()
    actor = unique_id()

    assert :ok =
             ParticipantEvents.publish_participant_removed(%{
               conversation_id: conversation_id,
               user_id: user_id,
               removed_by: actor
             })

    assert_receive {:kafka_published, @topic, ^conversation_id, env}, 1_000
    assert env.event_type == "conversation.participant_removed.v1"

    assert env.payload == %{
             "conversation_id" => conversation_id,
             "user_id" => user_id,
             "removed_by" => actor
           }
  end

  test "does NOT emit when publishing is disabled (default)" do
    # Flag stays off; capture adapter set so we'd see any stray publish.
    Application.put_env(:conversation_service, :conversation_publish_enabled, false)

    Application.put_env(
      :shared_infra,
      :kafka_producer_adapter,
      ConversationService.CaptureKafkaProducer
    )

    conversation_id = unique_id()

    assert :ok =
             ParticipantEvents.publish_participant_added(%{
               conversation_id: conversation_id,
               user_id: unique_id(),
               role: "member",
               added_by: unique_id()
             })

    refute_received {:kafka_published, _topic, ^conversation_id, _value}
  end

  test "emit returns :ok even when the producer raises (fire-and-forget never breaks the caller)" do
    Application.put_env(:conversation_service, :conversation_publish_enabled, true)

    Application.put_env(
      :shared_infra,
      :kafka_producer_adapter,
      ConversationService.FailingKafkaProducer
    )

    # The producer raises inside the Task; the caller must still get :ok.
    assert :ok =
             ParticipantEvents.publish_participant_added(%{
               conversation_id: unique_id(),
               user_id: unique_id(),
               role: "member",
               added_by: unique_id()
             })

    assert :ok =
             ParticipantEvents.publish_participant_removed(%{
               conversation_id: unique_id(),
               user_id: unique_id(),
               removed_by: unique_id()
             })
  end

  # Receives `count` published envelopes for this conversation; returns
  # `{%{user_id => payload}, last_envelope}`.
  defp collect_added(conversation_id, count) do
    Enum.reduce(1..count, {%{}, nil}, fn _i, {acc, _last} ->
      assert_receive {:kafka_published, @topic, ^conversation_id, env}, 1_000
      {Map.put(acc, env.payload["user_id"], env.payload), env}
    end)
  end

  defp unique_id, do: Ecto.UUID.generate()
end
