defmodule NotificationService.NotificationsTest do
  @moduledoc """
  Recipient fan-out proofs — Repo-only, in-process (DataCase sandbox), NO broker.

  Behavior CHANGE (sub-slice c): `apply_message_created/1` now writes ONE notification per
  ACTIVE conversation participant (from `conversation_participants_readmodel`), EXCLUDING the
  sender — not one row per event. Idempotency is per `(source_event_id, recipient_user_id)`.
  """
  use NotificationService.DataCase, async: false

  import Ecto.Query

  alias NotificationService.Notifications
  alias NotificationService.Schemas.ConversationParticipantReadModel
  alias NotificationService.Schemas.Notification
  alias NotificationService.Schemas.ProcessedEvent

  @tag :postgres_integration
  test "fans out one notification per active participant, excluding the sender" do
    conversation_id = Ecto.UUID.generate()
    sender = Ecto.UUID.generate()
    member_a = Ecto.UUID.generate()
    member_b = Ecto.UUID.generate()

    # 3 active participants; sender is one of them.
    seed_participant(conversation_id, sender)
    seed_participant(conversation_id, member_a)
    seed_participant(conversation_id, member_b)

    event_id = Ecto.UUID.generate()

    assert {:ok, :applied} =
             Notifications.apply_message_created(envelope(event_id, conversation_id, sender))

    recipients = recipients_for(event_id)
    assert length(recipients) == 2
    assert sender not in recipients
    assert Enum.sort(recipients) == Enum.sort([member_a, member_b])
    assert ledger_count(event_id) == 1
  end

  @tag :postgres_integration
  test "redelivery of the same event creates no duplicate per-recipient notifications" do
    conversation_id = Ecto.UUID.generate()
    sender = Ecto.UUID.generate()
    seed_participant(conversation_id, sender)
    seed_participant(conversation_id, Ecto.UUID.generate())
    seed_participant(conversation_id, Ecto.UUID.generate())

    event_id = Ecto.UUID.generate()
    env = envelope(event_id, conversation_id, sender)

    assert {:ok, :applied} = Notifications.apply_message_created(env)
    assert {:ok, :duplicate} = Notifications.apply_message_created(env)

    # Still exactly 2 (per-recipient unique index; ledger gated the redelivery).
    assert length(recipients_for(event_id)) == 2
  end

  @tag :postgres_integration
  test "cold-start: no read-model participants for the conversation -> 0 notifications, no crash" do
    conversation_id = Ecto.UUID.generate()
    event_id = Ecto.UUID.generate()

    assert {:ok, :applied} =
             Notifications.apply_message_created(
               envelope(event_id, conversation_id, Ecto.UUID.generate())
             )

    assert recipients_for(event_id) == []
    # Event still recorded in the ledger (processed; just nobody to notify yet).
    assert ledger_count(event_id) == 1
  end

  @tag :postgres_integration
  test "a participant added to the read-model is included in a subsequent message's fan-out" do
    conversation_id = Ecto.UUID.generate()
    sender = Ecto.UUID.generate()
    existing = Ecto.UUID.generate()
    seed_participant(conversation_id, sender)
    seed_participant(conversation_id, existing)

    # First message → 1 recipient (existing).
    event1 = Ecto.UUID.generate()

    assert {:ok, :applied} =
             Notifications.apply_message_created(envelope(event1, conversation_id, sender))

    assert recipients_for(event1) == [existing]

    # New participant joins the read-model.
    newcomer = Ecto.UUID.generate()
    seed_participant(conversation_id, newcomer)

    # Second (distinct) message → both non-sender participants notified.
    event2 = Ecto.UUID.generate()

    assert {:ok, :applied} =
             Notifications.apply_message_created(envelope(event2, conversation_id, sender))

    assert Enum.sort(recipients_for(event2)) == Enum.sort([existing, newcomer])
  end

  @tag :postgres_integration
  test "rejects a structurally invalid event (missing/bad ids)" do
    assert {:error, :invalid_event} = Notifications.apply_message_created(%{"payload" => %{}})

    assert {:error, :invalid_event} =
             Notifications.apply_message_created(%{
               "event_id" => Ecto.UUID.generate(),
               "payload" => %{"conversation_id" => "not-a-uuid"}
             })
  end

  defp seed_participant(conversation_id, user_id) do
    Repo.insert_all(ConversationParticipantReadModel, [
      %{
        conversation_id: conversation_id,
        user_id: user_id,
        active: true,
        role: "member",
        last_event_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      }
    ])
  end

  defp recipients_for(event_id) do
    Repo.all(
      from(n in Notification, where: n.source_event_id == ^event_id, select: n.recipient_user_id)
    )
  end

  defp ledger_count(event_id) do
    Repo.aggregate(
      from(p in ProcessedEvent,
        where: p.consumer == ^Notifications.consumer_name() and p.event_id == ^event_id
      ),
      :count
    )
  end

  defp envelope(event_id, conversation_id, sender_user_id) do
    %{
      "event_id" => event_id,
      "event_type" => "message.created.v1",
      "payload" => %{
        "conversation_id" => conversation_id,
        "message_id" => Ecto.UUID.generate(),
        "sender_user_id" => sender_user_id,
        "message_type" => "text",
        "created_at" => "2026-06-18T10:00:00Z"
      }
    }
  end
end
