defmodule ConversationService.ParticipantEventsIntegrationTest do
  @moduledoc """
  Proves the emit-after-persist WIRING: a real DB-backed create/add/remove actually emits
  the participant events (fire-and-forget, captured via an in-process stub adapter). Tagged
  `:postgres_integration` (needs the local test DB). The emit Task does NOT touch the DB, so
  it is unaffected by the sandbox; we assert via the captured messages.
  """
  use ExUnit.Case, async: false

  alias ConversationService.Conversations
  alias ConversationService.Participants
  alias ConversationService.Repo

  @topic "conversation.events.v1"

  setup do
    previous = %{
      persistence: Application.get_env(:conversation_service, :conversation_persistence, false),
      publish: Application.get_env(:conversation_service, :conversation_publish_enabled, false),
      producer: Application.get_env(:shared_infra, :kafka_producer_adapter)
    }

    Application.put_env(:conversation_service, :conversation_persistence, true)
    Application.put_env(:conversation_service, :conversation_publish_enabled, true)

    Application.put_env(
      :shared_infra,
      :kafka_producer_adapter,
      ConversationService.CaptureKafkaProducer
    )

    Application.put_env(:shared_infra, :capture_test_pid, self())

    start_repo!(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    on_exit(fn ->
      Application.delete_env(:shared_infra, :capture_test_pid)
      Application.put_env(:conversation_service, :conversation_persistence, previous.persistence)
      Application.put_env(:conversation_service, :conversation_publish_enabled, previous.publish)

      if previous.producer do
        Application.put_env(:shared_infra, :kafka_producer_adapter, previous.producer)
      else
        Application.delete_env(:shared_infra, :kafka_producer_adapter)
      end
    end)

    :ok
  end

  @tag :postgres_integration
  test "create emits participant_added for each initial participant; add and remove emit too" do
    creator = Ecto.UUID.generate()
    member = Ecto.UUID.generate()
    added_user = Ecto.UUID.generate()

    insert_user_auth_parent!(creator)
    insert_user_auth_parent!(member)
    insert_user_auth_parent!(added_user)

    # CREATE → one participant_added per initial participant (creator=owner, member=member).
    assert {:ok, conversation} =
             Conversations.create_conversation(%{
               "type" => "group",
               "title" => "Events",
               "created_by" => creator,
               "participant_user_ids" => [member]
             })

    conversation_id = conversation.conversation_id

    assert_receive {:kafka_published, @topic, ^conversation_id, env1}, 1_000
    assert_receive {:kafka_published, @topic, ^conversation_id, env2}, 1_000
    roles = Map.new([env1, env2], fn e -> {e.payload["user_id"], e.payload["role"]} end)
    assert roles[creator] == "owner"
    assert roles[member] == "member"

    for e <- [env1, env2] do
      assert e.event_type == "conversation.participant_added.v1"
      assert e.payload["added_by"] == creator
    end

    # ADD → participant_added for the new user.
    assert {:ok, _} =
             Participants.add_participant(%{
               "conversation_id" => conversation_id,
               "user_id" => added_user,
               "actor_user_id" => creator,
               "role" => "member"
             })

    assert_receive {:kafka_published, @topic, ^conversation_id, add_env}, 1_000
    assert add_env.event_type == "conversation.participant_added.v1"
    assert add_env.payload["user_id"] == added_user
    assert add_env.payload["added_by"] == creator

    # REMOVE → participant_removed for that user.
    assert {:ok, _} =
             Participants.remove_participant(%{
               "conversation_id" => conversation_id,
               "user_id" => added_user,
               "actor_user_id" => creator
             })

    assert_receive {:kafka_published, @topic, ^conversation_id, rm_env}, 1_000
    assert rm_env.event_type == "conversation.participant_removed.v1"
    assert rm_env.payload["user_id"] == added_user
    assert rm_env.payload["removed_by"] == creator
  end

  defp insert_user_auth_parent!(user_id) do
    Repo.query!(
      """
      INSERT INTO users_auth (id, email, status)
      VALUES ($1, $2, 'active')
      """,
      [
        Ecto.UUID.dump!(user_id),
        "conversation-#{System.unique_integer([:positive])}@example.test"
      ]
    )
  end

  defp start_repo!(repo) do
    case repo.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end
end
