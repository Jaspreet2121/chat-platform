defmodule NotificationService.ParticipantReadModelTest do
  @moduledoc """
  Convergence + idempotency proofs for the participant read-model — Repo-only, in-process
  (DataCase sandbox), NO broker. The OUT-OF-ORDER test is the key proof: last-writer-wins by
  `occurred_at` makes add/remove converge to the right final state regardless of arrival order.
  """
  use NotificationService.DataCase, async: false

  alias NotificationService.ParticipantReadModel
  alias NotificationService.Schemas.ConversationParticipantReadModel

  @t1 "2026-06-18T10:00:00Z"
  @t2 "2026-06-18T10:00:05Z"

  @tag :postgres_integration
  test "duplicate add (same event_id) applies once; row is active" do
    conversation_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()
    event_id = Ecto.UUID.generate()

    env = added(event_id, conversation_id, user_id, "member", @t1)

    assert {:ok, :applied} = ParticipantReadModel.apply_participant_added(env)
    assert {:ok, :duplicate} = ParticipantReadModel.apply_participant_added(env)

    row = get_row(conversation_id, user_id)
    assert row.active == true
    assert row.role == "member"
    assert ledger_count(event_id) == 1
  end

  @tag :postgres_integration
  test "duplicate remove (same event_id) is idempotent inactive" do
    conversation_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()
    event_id = Ecto.UUID.generate()

    env = removed(event_id, conversation_id, user_id, @t1)

    assert {:ok, :applied} = ParticipantReadModel.apply_participant_removed(env)
    assert {:ok, :duplicate} = ParticipantReadModel.apply_participant_removed(env)

    assert get_row(conversation_id, user_id).active == false
    assert ledger_count(event_id) == 1
  end

  @tag :postgres_integration
  test "add then remove IN ORDER -> final inactive" do
    conversation_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()

    assert {:ok, :applied} =
             ParticipantReadModel.apply_participant_added(
               added(Ecto.UUID.generate(), conversation_id, user_id, "member", @t1)
             )

    assert {:ok, :applied} =
             ParticipantReadModel.apply_participant_removed(
               removed(Ecto.UUID.generate(), conversation_id, user_id, @t2)
             )

    assert get_row(conversation_id, user_id).active == false
  end

  @tag :postgres_integration
  test "OUT OF ORDER: real add(t1) then remove(t2), DELIVERED remove(t2) then add(t1) -> inactive" do
    conversation_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()

    # Deliver the NEWER remove (t2) first...
    assert {:ok, :applied} =
             ParticipantReadModel.apply_participant_removed(
               removed(Ecto.UUID.generate(), conversation_id, user_id, @t2)
             )

    # ...then the OLDER add (t1). LWW must ignore the stale add's state change.
    assert {:ok, :applied} =
             ParticipantReadModel.apply_participant_added(
               added(Ecto.UUID.generate(), conversation_id, user_id, "member", @t1)
             )

    row = get_row(conversation_id, user_id)
    assert row.active == false, "older add must NOT resurrect a removed participant"
    assert DateTime.to_iso8601(row.last_event_at) == "2026-06-18T10:00:05.000000Z"
  end

  @tag :postgres_integration
  test "real remove(t1) then add(t2) -> final active (both directions converge)" do
    conversation_id = Ecto.UUID.generate()
    user_id = Ecto.UUID.generate()

    assert {:ok, :applied} =
             ParticipantReadModel.apply_participant_removed(
               removed(Ecto.UUID.generate(), conversation_id, user_id, @t1)
             )

    assert {:ok, :applied} =
             ParticipantReadModel.apply_participant_added(
               added(Ecto.UUID.generate(), conversation_id, user_id, "admin", @t2)
             )

    row = get_row(conversation_id, user_id)
    assert row.active == true
    assert row.role == "admin"
  end

  defp added(event_id, conversation_id, user_id, role, occurred_at) do
    %{
      "event_id" => event_id,
      "event_type" => "conversation.participant_added.v1",
      "occurred_at" => occurred_at,
      "payload" => %{
        "conversation_id" => conversation_id,
        "user_id" => user_id,
        "role" => role,
        "added_by" => Ecto.UUID.generate()
      }
    }
  end

  defp removed(event_id, conversation_id, user_id, occurred_at) do
    %{
      "event_id" => event_id,
      "event_type" => "conversation.participant_removed.v1",
      "occurred_at" => occurred_at,
      "payload" => %{
        "conversation_id" => conversation_id,
        "user_id" => user_id,
        "removed_by" => Ecto.UUID.generate()
      }
    }
  end

  defp get_row(conversation_id, user_id) do
    Repo.get_by(ConversationParticipantReadModel,
      conversation_id: conversation_id,
      user_id: user_id
    )
  end

  defp ledger_count(event_id) do
    import Ecto.Query
    alias NotificationService.Schemas.ProcessedEvent

    Repo.aggregate(
      from(p in ProcessedEvent,
        where: p.consumer == ^ParticipantReadModel.consumer_name() and p.event_id == ^event_id
      ),
      :count
    )
  end
end
