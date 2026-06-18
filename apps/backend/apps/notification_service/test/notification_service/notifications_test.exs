defmodule NotificationService.NotificationsTest do
  @moduledoc """
  Exactly-once proof for idempotent notification creation — Repo-only, in-process (uses the
  DataCase sandbox), NO broker. Deterministic: applying the SAME event_id twice must create
  exactly ONE notification row.
  """
  use NotificationService.DataCase, async: false

  import Ecto.Query

  alias NotificationService.Notifications
  alias NotificationService.Schemas.Notification
  alias NotificationService.Schemas.ProcessedEvent

  @tag :postgres_integration
  test "same event_id creates exactly one notification; distinct events create more" do
    event_id = Ecto.UUID.generate()
    envelope = envelope(event_id, Ecto.UUID.generate(), Ecto.UUID.generate(), Ecto.UUID.generate())

    # First delivery applies; redelivery of the SAME event_id is a no-op duplicate.
    assert {:ok, :applied} = Notifications.apply_message_created(envelope)
    assert {:ok, :duplicate} = Notifications.apply_message_created(envelope)

    assert 1 == Repo.aggregate(from(n in Notification, where: n.source_event_id == ^event_id), :count)

    notification = Repo.one(from(n in Notification, where: n.source_event_id == ^event_id))
    assert notification.type == "message_created"
    assert notification.read == false
    assert notification.sender_user_id

    # Exactly one ledger row for the (consumer, event_id).
    assert 1 ==
             Repo.aggregate(
               from(p in ProcessedEvent,
                 where: p.consumer == ^Notifications.consumer_name() and p.event_id == ^event_id
               ),
               :count
             )

    # A DISTINCT event creates another notification.
    assert {:ok, :applied} =
             Notifications.apply_message_created(
               envelope(Ecto.UUID.generate(), Ecto.UUID.generate(), Ecto.UUID.generate(), Ecto.UUID.generate())
             )

    assert 2 == Repo.aggregate(from(n in Notification, where: n.type == "message_created"), :count)
  end

  @tag :postgres_integration
  test "rejects a structurally invalid event (missing/bad ids)" do
    assert {:error, :invalid_event} =
             Notifications.apply_message_created(%{"payload" => %{}})

    assert {:error, :invalid_event} =
             Notifications.apply_message_created(%{
               "event_id" => Ecto.UUID.generate(),
               "payload" => %{"conversation_id" => "not-a-uuid"}
             })
  end

  defp envelope(event_id, conversation_id, message_id, sender_user_id) do
    %{
      "event_id" => event_id,
      "event_type" => "message.created.v1",
      "payload" => %{
        "conversation_id" => conversation_id,
        "message_id" => message_id,
        "sender_user_id" => sender_user_id,
        "message_type" => "text",
        "created_at" => "2026-06-18T10:00:00Z"
      }
    }
  end
end
