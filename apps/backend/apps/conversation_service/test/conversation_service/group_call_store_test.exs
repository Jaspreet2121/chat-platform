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

  # --- C2: add-participant + authorization predicate ---------------------------------------------

  @tag :postgres_integration
  test "add_call_participant: an outside non-member gets an invited row, can be authorized + join" do
    {owner, [a, _b], conv_id} = group_of(2)
    outsider = new_user!()

    {:ok, %{call: call}} =
      CallStore.create_group_call(%{
        "initiator_id" => owner,
        "conversation_id" => conv_id,
        "type" => "voice"
      })

    {:ok, _} = CallStore.join_group_call(%{"call_id" => call.id, "user_id" => a})

    # Before adding: the outsider is neither a participant nor joinable.
    assert {:ok, %{authorized: false}} =
             CallStore.call_participant?(%{"call_id" => call.id, "user_id" => outsider})

    assert {:error, :not_a_member} =
             CallStore.join_group_call(%{"call_id" => call.id, "user_id" => outsider})

    # Owner adds the outsider → invited row + ring metadata.
    assert {:ok, %{added_user_id: ^outsider, room: room, type: "voice", conversation_id: ^conv_id}} =
             CallStore.add_call_participant(%{
               "call_id" => call.id,
               "actor_id" => owner,
               "user_id" => outsider
             })

    assert String.starts_with?(room, "call-")

    # After adding: authorized, and can now join despite never being a conversation member.
    assert {:ok, %{authorized: true}} =
             CallStore.call_participant?(%{"call_id" => call.id, "user_id" => outsider})

    assert {:ok, %{participant: %{status: "joined"}}} =
             CallStore.join_group_call(%{"call_id" => call.id, "user_id" => outsider})
  end

  @tag :postgres_integration
  test "add_call_participant: re-adding someone already invited/joined is an idempotent no-op" do
    {owner, [a, _b], conv_id} = group_of(2)

    {:ok, %{call: call}} =
      CallStore.create_group_call(%{
        "initiator_id" => owner,
        "conversation_id" => conv_id,
        "type" => "voice"
      })

    # `a` was invited at create; re-adding is a no-op that still succeeds (and leaves one row).
    assert {:ok, %{added_user_id: ^a}} =
             CallStore.add_call_participant(%{
               "call_id" => call.id,
               "actor_id" => owner,
               "user_id" => a
             })

    {:ok, %{participants: parts}} =
      CallStore.get_call_with_participants(%{"call_id" => call.id})

    a_rows = Enum.filter(parts, &(&1.user_id == a))
    assert length(a_rows) == 1
    assert hd(a_rows).status == "invited"
  end

  @tag :postgres_integration
  test "add_call_participant: admins_only blocks a plain member from adding, allows the owner" do
    {owner, [member, _b], conv_id} = group_of(2)
    outsider = new_user!()

    {:ok, _} =
      Participants.set_group_settings(%{
        "conversation_id" => conv_id,
        "actor_user_id" => owner,
        "only_admins_can_send" => false,
        "call_start_permission" => "admins_only"
      })

    {:ok, %{call: call}} =
      CallStore.create_group_call(%{
        "initiator_id" => owner,
        "conversation_id" => conv_id,
        "type" => "voice"
      })

    # A plain member cannot add under admins_only.
    assert {:error, :call_add_forbidden} =
             CallStore.add_call_participant(%{
               "call_id" => call.id,
               "actor_id" => member,
               "user_id" => outsider
             })

    # The owner still can.
    assert {:ok, %{added_user_id: ^outsider}} =
             CallStore.add_call_participant(%{
               "call_id" => call.id,
               "actor_id" => owner,
               "user_id" => outsider
             })
  end

  @tag :postgres_integration
  test "add_call_participant: rejected on an ended call" do
    {owner, [_a, _b], conv_id} = group_of(2)
    outsider = new_user!()

    {:ok, %{call: call}} =
      CallStore.create_group_call(%{
        "initiator_id" => owner,
        "conversation_id" => conv_id,
        "type" => "voice"
      })

    # Owner (only joined party) leaves → call closes (nobody joined → missed).
    {:ok, _} = CallStore.leave_group_call(%{"call_id" => call.id, "user_id" => owner})

    assert {:error, :call_not_joinable} =
             CallStore.add_call_participant(%{
               "call_id" => call.id,
               "actor_id" => owner,
               "user_id" => outsider
             })
  end

  # --- C3b: promote a 1-on-1 (direct) call to a group call ---------------------------------------

  @tag :postgres_integration
  test "promote_direct_to_group: flips kind→group, seats both parties joined, invites the new person (same room)" do
    {owner, [callee, outsider], conv_id} = group_of(2)
    {:ok, direct} = accepted_direct_call(owner, callee, conv_id, "video")

    assert {:ok, result} =
             CallStore.promote_direct_to_group(%{
               "call_id" => direct.id,
               "actor_id" => owner,
               "user_id" => outsider
             })

    assert result.added_user_id == outsider
    # SAME room — promotion must not reconnect.
    assert result.room == direct.room_name
    assert Enum.sort(result.existing_parties) == Enum.sort([owner, callee])

    {:ok, %{call: call, participants: parts}} =
      CallStore.get_call_with_participants(%{"call_id" => direct.id})

    assert call.kind == "group"
    assert call.status == "ongoing"
    assert call.room_name == direct.room_name

    by_user = Map.new(parts, &{&1.user_id, &1.status})
    assert by_user[owner] == "joined"
    assert by_user[callee] == "joined"
    assert by_user[outsider] == "invited"
  end

  @tag :postgres_integration
  test "promote_direct_to_group: EITHER peer may promote (the callee, not just the caller)" do
    {owner, [callee, outsider], conv_id} = group_of(2)
    {:ok, direct} = accepted_direct_call(owner, callee, conv_id, "voice")

    assert {:ok, %{added_user_id: ^outsider}} =
             CallStore.promote_direct_to_group(%{
               "call_id" => direct.id,
               "actor_id" => callee,
               "user_id" => outsider
             })
  end

  @tag :postgres_integration
  test "promote_direct_to_group: a non-party actor is forbidden" do
    {owner, [callee, outsider], conv_id} = group_of(2)
    stranger = new_user!()
    {:ok, direct} = accepted_direct_call(owner, callee, conv_id, "voice")

    assert {:error, :promote_forbidden} =
             CallStore.promote_direct_to_group(%{
               "call_id" => direct.id,
               "actor_id" => stranger,
               "user_id" => outsider
             })

    # And the call is untouched — still a direct, accepted 1-on-1.
    {:ok, still_direct} = CallStore.get_call(%{"call_id" => direct.id})
    assert still_direct.kind == "direct"
    assert still_direct.status == "accepted"
  end

  # --- helpers -----------------------------------------------------------------------------------

  # A LIVE 1-on-1 (direct) call: create (ringing) then mark_answered (→ "accepted"). Returns {:ok, call}.
  defp accepted_direct_call(caller_id, callee_id, conversation_id, type) do
    {:ok, call} =
      CallStore.create_call(%{
        "caller_id" => caller_id,
        "callee_id" => callee_id,
        "type" => type,
        "conversation_id" => conversation_id
      })

    {:ok, _} = CallStore.mark_answered(%{"call_id" => call.id})
    {:ok, call}
  end

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

  # A fresh app user (auth parent only, NOT in any conversation) — an "outside person" for add tests.
  defp new_user! do
    user_id = Ecto.UUID.generate()
    insert_user_auth_parent!(user_id)
    user_id
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
