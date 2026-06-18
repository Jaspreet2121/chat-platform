defmodule NotificationService.ParticipantReadModelInvalidTest do
  @moduledoc """
  PLAIN (Docker-free) test: a structurally invalid event is rejected with
  `{:error, :invalid_event}` BEFORE any DB work, so this needs no Repo (no DataCase,
  no sandbox). The valid-path convergence proofs live in `participant_read_model_test.exs`
  (postgres_integration).
  """
  use ExUnit.Case, async: true

  alias NotificationService.ParticipantReadModel

  test "rejects missing/bad ids before touching the Repo" do
    assert {:error, :invalid_event} =
             ParticipantReadModel.apply_participant_added(%{"payload" => %{}})

    assert {:error, :invalid_event} =
             ParticipantReadModel.apply_participant_added(%{
               "event_id" => Ecto.UUID.generate(),
               "payload" => %{"conversation_id" => "not-a-uuid", "user_id" => Ecto.UUID.generate()}
             })

    assert {:error, :invalid_event} =
             ParticipantReadModel.apply_participant_removed(%{
               "event_id" => Ecto.UUID.generate(),
               "payload" => %{"conversation_id" => Ecto.UUID.generate()}
             })
  end
end
