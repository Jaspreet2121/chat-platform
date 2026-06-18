defmodule ConversationService.ParticipantEvents do
  @moduledoc """
  Fire-and-forget Kafka emission of participant-change events, mirroring
  `MessageService.Messages.publish_message_created/1` exactly: flag-gated
  (`CONVERSATION_PUBLISH_ENABLED`, default off), wrapped in `Task.start` so a create/add/
  remove NEVER blocks on or fails because of the broker, with try/rescue/catch. With the
  default `NoopProducer` adapter nothing connects, so plain `mix test` stays Docker-free.

  Emitted to topic `conversation.events.v1`, key = `conversation_id` (per-conversation
  ordering). Sets the event contract that notification-service's participant read-model
  (sub-slice b) will consume:

    * `conversation.participant_added.v1`   → `{conversation_id, user_id, role, added_by}`
    * `conversation.participant_removed.v1` → `{conversation_id, user_id, removed_by}`

  Initial participants created with a conversation are emitted as `participant_added`
  (one per participant) so the read-model is complete from `participant_added`/`removed`
  alone, without a separate `conversation.created` seed event.
  """

  require Logger

  alias SharedInfra.Events.Envelope
  alias SharedInfra.Kafka.Producer

  @topic "conversation.events.v1"
  @client :conversation_service_kafka_client

  @doc "conversation-service's own brod client name (configurable per-call client on the producer)."
  def client_name, do: @client

  @doc """
  Emit one `participant_added` per initial participant of a newly-created conversation.
  Role is `owner` for the creator, `member` otherwise; `added_by` is the creator.
  """
  def publish_initial_participants(conversation_id, created_by, participant_user_ids) do
    Enum.each(participant_user_ids, fn user_id ->
      role = if user_id == created_by, do: "owner", else: "member"

      publish_participant_added(%{
        conversation_id: conversation_id,
        user_id: user_id,
        role: role,
        added_by: created_by
      })
    end)

    :ok
  end

  def publish_participant_added(%{
        conversation_id: conversation_id,
        user_id: user_id,
        role: role,
        added_by: added_by
      }) do
    publish("conversation.participant_added.v1", conversation_id, %{
      "conversation_id" => conversation_id,
      "user_id" => user_id,
      "role" => role,
      "added_by" => added_by
    })
  end

  def publish_participant_removed(%{
        conversation_id: conversation_id,
        user_id: user_id,
        removed_by: removed_by
      }) do
    publish("conversation.participant_removed.v1", conversation_id, %{
      "conversation_id" => conversation_id,
      "user_id" => user_id,
      "removed_by" => removed_by
    })
  end

  # Fire-and-forget: Task.start (unlinked) so the caller never blocks on a broker / lazy
  # producer-start, and a publish crash can't reach the caller. Disabled by default; the
  # default producer adapter is the non-connecting NoopProducer, so nothing connects.
  defp publish(event_type, conversation_id, payload) do
    if publish_enabled?() do
      Task.start(fn -> do_publish(event_type, conversation_id, payload) end)
    end

    :ok
  end

  defp do_publish(event_type, conversation_id, payload) do
    case build_envelope(event_type, payload) do
      {:ok, envelope} ->
        Producer.produce(@topic, conversation_id, envelope, client: @client)

      {:error, reason} ->
        Logger.warning("#{event_type} envelope invalid, skipping publish: #{inspect(reason)}")
    end
  rescue
    error -> Logger.warning("#{event_type} publish raised, ignored: #{inspect(error)}")
  catch
    kind, value -> Logger.warning("#{event_type} publish #{kind}, ignored: #{inspect(value)}")
  end

  defp build_envelope(event_type, payload) do
    Envelope.build(%{
      event_id: Ecto.UUID.generate(),
      event_type: event_type,
      event_version: 1,
      producer: "conversation-service",
      occurred_at: DateTime.to_iso8601(DateTime.utc_now()),
      correlation_id: Ecto.UUID.generate(),
      payload: payload
    })
  end

  defp publish_enabled? do
    Application.get_env(:conversation_service, :conversation_publish_enabled, false) ||
      System.get_env("CONVERSATION_PUBLISH_ENABLED") in ["true", "1", "yes"]
  end
end
