defmodule ConversationService.MessageRequestReplyAcceptTest do
  @moduledoc """
  IMPLICIT ACCEPT (130) — a message request the RECIPIENT answers is accepted by the answering.

  One test, both directions, because the two are the same claim: the clear is keyed to the sender of
  the message, so proving the recipient clears it without proving the original sender does NOT would
  prove nothing at all.

  `request_accepted: true` in the authorize_send disposition IS the accept event: both send paths turn
  exactly that flag into the same `:pref` conversation_updated frame the accept endpoint broadcasts,
  so asserting on the flag asserts on the event's one trigger.

  Mutations this is RED for:

    * dropping the `accepted_on_reply/2` call from the direct branch of authorize_send
    * clearing the flag for whoever sends (losing accept/1's `user_id = $2` predicate)
    * returning `%{authorized: true}` instead of `%{authorized: true, request_accepted: true}`
  """
  use ConversationService.DataCase, async: false

  alias ConversationService.{Conversations, MessageRequests, Participants}

  setup do
    previous = Application.get_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:conversation_service, :conversation_persistence, true)

    on_exit(fn ->
      Application.put_env(:conversation_service, :conversation_persistence, previous)
    end)

    :ok
  end

  defp user!(name) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, email, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2, 'x', now(), now())",
      [id, "#{name}-#{id}@test.local"]
    )

    id
  end

  # The REAL creation path, so the pending stamp is made by the code that makes it in production.
  defp create_direct!(creator, peer) do
    {:ok, response} =
      Conversations.create_conversation(%{
        "type" => "direct",
        "created_by" => creator,
        "participant_user_ids" => [creator, peer]
      })

    Map.get(response, :conversation_id) || Map.get(response, "conversation_id")
  end

  defp send_as(conversation_id, user_id) do
    {:ok, disposition} =
      Participants.authorize_send(%{
        "conversation_id" => conversation_id,
        "user_id" => user_id
      })

    disposition
  end

  @tag :postgres_integration
  test "a recipient's reply accepts the request; the original sender's messages never do" do
    sender = user!("stranger")
    recipient = user!("recipient")
    conversation_id = create_direct!(sender, recipient)

    # Precondition: the stranger's first message left the RECIPIENT's row pending, and only theirs.
    assert MessageRequests.pending?(conversation_id, recipient)
    refute MessageRequests.pending?(conversation_id, sender)

    # The ORIGINAL SENDER keeps sending into the unanswered request. Nothing is accepted, the flag
    # survives, and no accept event is signalled — the request budget stays intact.
    sender_disposition = send_as(conversation_id, sender)

    refute Map.get(sender_disposition, :request_accepted)
    assert MessageRequests.pending?(conversation_id, recipient)

    # The RECIPIENT replies. That IS the accept: same clear, and the flag the send paths turn into
    # the accept frame.
    recipient_disposition = send_as(conversation_id, recipient)

    assert Map.get(recipient_disposition, :request_accepted) == true
    refute MessageRequests.pending?(conversation_id, recipient)

    # And it is settled, not merely toggled: the next reply has nothing left to accept, so it emits
    # no second accept event.
    refute Map.get(send_as(conversation_id, recipient), :request_accepted)
  end
end
