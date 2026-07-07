defmodule ConversationService.GroupCallStoreTest do
  @moduledoc """
  Phase-3 group-call lifecycle (CallStore). Postgres-integration (needs a real DB + the 067/068 schema),
  excluded from the plain Docker-free `mix test` run like the other conversation_service DB tests. Seeds a
  real group conversation (owner + members) via Conversations.create_conversation so membership + role
  checks run against actual participant rows.
  """
  use ExUnit.Case, async: false

  alias ConversationService.CallStore
  alias ConversationService.Conversations
  alias ConversationService.Participants
  alias ConversationService.Repo

  @tag :postgres_integration
  test "create_group_call: initiator joined, others invited; group call ringing with nil callee" do
    {owner, [a, b], conv_id} = group_of(2)

    assert {:ok, %{call: call, participants: parts, member_ids: member_ids}} =
             CallStore.create_group_call(%{
               "initiator_id" => owner,
               "conversation_id" => conv_id,
               "type" => "voice"
             })

    assert call.kind == "group"
    assert call.status == "ringing"
    assert call.caller_id == owner
    assert is_nil(call.callee_id)
    assert call.conversation_id == conv_id
    assert is_binary(call.room_name) and String.starts_with?(call.room_name, "call-")

    # member_ids = everyone to ring (members minus initiator).
    assert Enum.sort(member_ids) == Enum.sort([a, b])

    by_user = Map.new(parts, &{&1.user_id, &1.status})
    assert by_user[owner] == "joined"
    assert by_user[a] == "invited"
    assert by_user[b] == "invited"
  end

  @tag :postgres_integration
  test "join_group_call: a late join flips the call ringing → ongoing" do
    {owner, [a, _b], conv_id} = group_of(2)

    {:ok, %{call: call}} =
      CallStore.create_group_call(%{
        "initiator_id" => owner,
        "conversation_id" => conv_id,
        "type" => "video"
      })

    assert call.status == "ringing"

    assert {:ok, %{call: joined_call, participant: participant}} =
             CallStore.join_group_call(%{"call_id" => call.id, "user_id" => a})

    assert joined_call.status == "ongoing"
    assert participant.status == "joined"
    assert is_binary(participant.joined_at)
  end

  @tag :postgres_integration
  test "leave_group_call: the last participant to leave ends the call" do
    {owner, [a, b], conv_id} = group_of(2)

    {:ok, %{call: call}} =
      CallStore.create_group_call(%{
        "initiator_id" => owner,
        "conversation_id" => conv_id,
        "type" => "voice"
      })

    # a joins (→ ongoing); b never answers → decline so no invite is left pending.
    {:ok, _} = CallStore.join_group_call(%{"call_id" => call.id, "user_id" => a})
    {:ok, _} = CallStore.decline_group_call(%{"call_id" => call.id, "user_id" => b})

    # a leaves → owner still joined → call stays open.
    assert {:ok, %{call: still_open}} =
             CallStore.leave_group_call(%{"call_id" => call.id, "user_id" => a})

    assert still_open.status == "ongoing"

    # owner leaves → nobody joined, nobody invited → call ends.
    assert {:ok, %{call: closed}} =
             CallStore.leave_group_call(%{"call_id" => call.id, "user_id" => owner})

    assert closed.status == "ended"
    assert is_binary(closed.ended_at)
  end

  @tag :postgres_integration
  test "create_group_call: admins_only permission blocks a plain member, allows the owner" do
    {owner, [member, _b], conv_id} = group_of(2)

    # Owner sets the group to admins-only for starting calls (exercises the update path too).
    assert {:ok, _} =
             Participants.set_group_settings(%{
               "conversation_id" => conv_id,
               "actor_user_id" => owner,
               "only_admins_can_send" => false,
               "call_start_permission" => "admins_only"
             })

    # A plain member cannot start the call.
    assert {:error, :call_start_forbidden} =
             CallStore.create_group_call(%{
               "initiator_id" => member,
               "conversation_id" => conv_id,
               "type" => "voice"
             })

    # The owner still can.
    assert {:ok, %{call: %{status: "ringing"}}} =
             CallStore.create_group_call(%{
               "initiator_id" => owner,
               "conversation_id" => conv_id,
               "type" => "voice"
             })
  end

  # --- helpers -----------------------------------------------------------------------------------

  # A group conversation with an owner + `n` members. Returns {owner_id, member_ids, conversation_id}.
  defp group_of(n) do
    owner = Ecto.UUID.generate()
    members = for _ <- 1..n, do: Ecto.UUID.generate()
    Enum.each([owner | members], &insert_user_auth_parent!/1)

    {:ok, conv} =
      Conversations.create_conversation(%{
        "type" => "group",
        "title" => "Call Squad",
        "created_by" => owner,
        "participant_user_ids" => members
      })

    {owner, members, conv.conversation_id}
  end

  defp insert_user_auth_parent!(user_id) do
    Repo.query!(
      "INSERT INTO users_auth (id, email, status) VALUES ($1, $2, 'active')",
      [Ecto.UUID.dump!(user_id), "group-call-#{System.unique_integer([:positive])}@example.test"]
    )
  end

  setup do
    previous = Application.get_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:conversation_service, :conversation_persistence, true)

    start_repo!(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    on_exit(fn -> Application.put_env(:conversation_service, :conversation_persistence, previous) end)
    :ok
  end

  defp start_repo!(repo) do
    case repo.start_link() do
      {:ok, pid} -> Process.unlink(pid) && :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
