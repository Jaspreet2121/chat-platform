defmodule MessageService.Projections.ConversationSummaryTest do
  @moduledoc """
  Exactly-once proof for the idempotent projection — Repo-only, in-process (uses the
  DataCase sandbox), NO broker. Deterministic: applying the SAME event_id twice must
  increment the summary exactly once.
  """
  use MessageService.DataCase, async: false

  import Ecto.Query

  alias MessageService.Projections.ConversationSummary
  alias MessageService.Schemas.ConversationMessageSummary
  alias MessageService.Schemas.ProcessedEvent

  @tag :postgres_integration
  test "same event_id applies exactly once; distinct events increment" do
    conversation_id = Ecto.UUID.generate()
    event_id = Ecto.UUID.generate()
    envelope = envelope(event_id, conversation_id, Ecto.UUID.generate())

    # First delivery applies; redelivery of the SAME event_id is a no-op duplicate.
    assert {:ok, :applied} = ConversationSummary.apply_message_created(envelope)
    assert {:ok, :duplicate} = ConversationSummary.apply_message_created(envelope)

    summary = Repo.get(ConversationMessageSummary, conversation_id)
    assert summary.message_count == 1
    assert summary.last_message_id

    # Exactly one ledger row for the (consumer, event_id).
    assert 1 ==
             Repo.aggregate(
               from(p in ProcessedEvent,
                 where:
                   p.consumer == ^ConversationSummary.consumer_name() and p.event_id == ^event_id
               ),
               :count
             )

    # A DISTINCT event for the same conversation increments to 2.
    assert {:ok, :applied} =
             ConversationSummary.apply_message_created(
               envelope(Ecto.UUID.generate(), conversation_id, Ecto.UUID.generate())
             )

    assert Repo.get(ConversationMessageSummary, conversation_id).message_count == 2
  end

  @tag :postgres_integration
  test "rejects a structurally invalid event (missing event_id / conversation_id)" do
    assert {:error, :invalid_event} =
             ConversationSummary.apply_message_created(%{"payload" => %{}})

    assert {:error, :invalid_event} =
             ConversationSummary.apply_message_created(%{
               "event_id" => Ecto.UUID.generate(),
               "payload" => %{}
             })
  end

  defp envelope(event_id, conversation_id, message_id) do
    %{
      "event_id" => event_id,
      "event_type" => "message.created.v1",
      "payload" => %{
        "conversation_id" => conversation_id,
        "message_id" => message_id,
        "created_at" => "2026-06-18T10:00:00Z"
      }
    }
  end
end
