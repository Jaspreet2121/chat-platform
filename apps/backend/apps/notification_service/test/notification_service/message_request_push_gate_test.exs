defmodule NotificationService.MessageRequestPushGateTest do
  @moduledoc """
  MESSAGE REQUESTS (128) — the push gate.

  `active_recipients/2` is the ONE recipient set: the in-app notification rows, the web-push leg and
  the FCM leg all read it, so a recipient removed there is removed from all three. This suite proves
  the removal at that seam rather than three times over in the transports, which is exactly why the
  gate was put there.

  MUT-1 guard: a pending request pushes a notification → RED.

  The SEALED case is pinned explicitly. A sealed message rides this same fan-out and previews
  generically, so gating the recipient set covers it — but "covered by construction" is the kind of
  claim that stops being true quietly, so it is asserted rather than reasoned about.
  """
  use NotificationService.DataCase, async: false

  import Ecto.Query

  alias NotificationService.Notifications
  alias NotificationService.Schemas.ConversationParticipantReadModel
  alias NotificationService.Schemas.Notification

  defp seed_readmodel(conversation_id, user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all(ConversationParticipantReadModel, [
      %{
        conversation_id: conversation_id,
        user_id: user_id,
        active: true,
        role: "member",
        last_event_at: now,
        updated_at: now
      }
    ])
  end

  # The AUTHORITATIVE rows the gate joins against. Membership still comes from the readmodel; these
  # only ever subtract.
  defp seed_authoritative(conversation_id, creator, members, pending) do
    Repo.query!(
      "INSERT INTO conversations (id, type, created_by) VALUES ($1::text::uuid, 'direct', $2::text::uuid)",
      [conversation_id, creator]
    )

    for user_id <- members do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at, request_pending_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now(), " <>
          "CASE WHEN $3 THEN now() ELSE NULL END)",
        [conversation_id, user_id, user_id in pending]
      )
    end
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, phone_number, status) VALUES ($1::text::uuid, $2, 'active')",
      [id, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp recipients_for(event_id) do
    Repo.all(
      from(n in Notification, where: n.source_event_id == ^event_id, select: n.recipient_user_id)
    )
  end

  defp envelope(event_id, conversation_id, sender_user_id, message_type) do
    %{
      "event_id" => event_id,
      "event_type" => "message.created.v1",
      "payload" => %{
        "conversation_id" => conversation_id,
        "message_id" => Ecto.UUID.generate(),
        "sender_user_id" => sender_user_id,
        "message_type" => message_type,
        "created_at" => "2026-09-18T10:00:00Z"
      }
    }
  end

  @tag :postgres_integration
  test "MUT-1 guard: a recipient with a pending request gets NO notification and NO push" do
    conversation_id = Ecto.UUID.generate()
    sender = user!()
    recipient = user!()

    seed_readmodel(conversation_id, sender)
    seed_readmodel(conversation_id, recipient)
    seed_authoritative(conversation_id, sender, [sender, recipient], [recipient])

    event_id = Ecto.UUID.generate()

    assert {:ok, :applied} =
             Notifications.apply_message_created(
               envelope(event_id, conversation_id, sender, "text")
             )

    assert [] == recipients_for(event_id)
  end

  @tag :postgres_integration
  test "a SEALED message to a pending request is gated by the same seam" do
    conversation_id = Ecto.UUID.generate()
    sender = user!()
    recipient = user!()

    seed_readmodel(conversation_id, sender)
    seed_readmodel(conversation_id, recipient)
    seed_authoritative(conversation_id, sender, [sender, recipient], [recipient])

    event_id = Ecto.UUID.generate()

    assert {:ok, :applied} =
             Notifications.apply_message_created(
               envelope(event_id, conversation_id, sender, "sealed")
             )

    assert [] == recipients_for(event_id)
  end

  @tag :postgres_integration
  test "once ACCEPTED the same recipient is notified again" do
    conversation_id = Ecto.UUID.generate()
    sender = user!()
    recipient = user!()

    seed_readmodel(conversation_id, sender)
    seed_readmodel(conversation_id, recipient)
    seed_authoritative(conversation_id, sender, [sender, recipient], [])

    event_id = Ecto.UUID.generate()

    assert {:ok, :applied} =
             Notifications.apply_message_created(
               envelope(event_id, conversation_id, sender, "text")
             )

    assert [recipient] == recipients_for(event_id)
  end

  @tag :postgres_integration
  test "a readmodel row with NO authoritative row yet is still notified — the join only subtracts" do
    conversation_id = Ecto.UUID.generate()
    sender = Ecto.UUID.generate()
    recipient = Ecto.UUID.generate()

    seed_readmodel(conversation_id, sender)
    seed_readmodel(conversation_id, recipient)

    event_id = Ecto.UUID.generate()

    assert {:ok, :applied} =
             Notifications.apply_message_created(
               envelope(event_id, conversation_id, sender, "text")
             )

    assert [recipient] == recipients_for(event_id)
  end
end
