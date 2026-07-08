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

  # --- L1: call links (conversation-less "link" calls) -------------------------------------------

  @tag :postgres_integration
  test "create_call_link + get_call_link: an active link with a url-safe id" do
    creator = new_user!()

    assert {:ok, %{link: link}} =
             CallStore.create_call_link(%{
               "creator_id" => creator,
               "type" => "video",
               "require_approval" => true
             })

    assert is_binary(link.id) and byte_size(link.id) >= 8
    assert link.type == "video"
    assert link.require_approval == true
    assert link.active == true
    assert link.creator_id == creator

    assert {:ok, %{link: fetched}} = CallStore.get_call_link(%{"link_id" => link.id})
    assert fetched.id == link.id

    assert {:error, :link_not_found} = CallStore.get_call_link(%{"link_id" => "does-not-exist"})
  end

  @tag :postgres_integration
  test "join_call_link: first join creates a conversation-less kind=link call + joined participant" do
    creator = new_user!()
    joiner = new_user!()
    {:ok, %{link: link}} = CallStore.create_call_link(%{"creator_id" => creator, "type" => "voice"})

    assert {:ok, result} = CallStore.join_call_link(%{"link_id" => link.id, "user_id" => joiner})

    assert result.type == "voice"
    assert result.require_approval == false
    # First joiner is the effective host (caller_id).
    assert result.is_host == true
    assert String.starts_with?(result.room, "call-")

    {:ok, %{call: call, participants: parts}} =
      CallStore.get_call_with_participants(%{"call_id" => result.call.id})

    assert call.kind == "link"
    assert call.status == "ongoing"
    assert is_nil(call.conversation_id)
    assert call.caller_id == joiner

    by_user = Map.new(parts, &{&1.user_id, &1.status})
    assert by_user[joiner] == "joined"
  end

  @tag :postgres_integration
  test "join_call_link: a SECOND joiner reuses the SAME call/room (find-or-create by link_id)" do
    creator = new_user!()
    a = new_user!()
    b = new_user!()
    {:ok, %{link: link}} = CallStore.create_call_link(%{"creator_id" => creator, "type" => "video"})

    {:ok, first} = CallStore.join_call_link(%{"link_id" => link.id, "user_id" => a})
    {:ok, second} = CallStore.join_call_link(%{"link_id" => link.id, "user_id" => b})

    # Same call + same room; the second joiner is NOT the host (the first created + hosts it).
    assert second.call.id == first.call.id
    assert second.room == first.room
    assert first.is_host == true
    assert second.is_host == false

    {:ok, %{participants: parts}} =
      CallStore.get_call_with_participants(%{"call_id" => first.call.id})

    assert Enum.sort(Enum.map(parts, & &1.user_id)) == Enum.sort([a, b])
    assert Enum.all?(parts, &(&1.status == "joined"))
  end

  @tag :postgres_integration
  test "join_call_link: an inactive/missing link is rejected" do
    assert {:error, :link_not_found} =
             CallStore.join_call_link(%{"link_id" => "nope", "user_id" => new_user!()})
  end

  # --- L3a: call-link approval gate --------------------------------------------------------------

  @tag :postgres_integration
  test "approval link: host joins directly; a non-host lands pending_approval (token denied)" do
    host = new_user!()
    joiner = new_user!()
    {:ok, %{link: link}} =
      CallStore.create_call_link(%{"creator_id" => host, "type" => "video", "require_approval" => true})

    # Host is the FIRST joiner → joined directly (caller_id/host) + token-authorized.
    assert {:ok, %{status: "joined", is_host: true, call: hostcall}} =
             CallStore.join_call_link(%{"link_id" => link.id, "user_id" => host})

    assert {:ok, %{authorized: true}} =
             CallStore.call_participant?(%{"call_id" => hostcall.id, "user_id" => host})

    # Non-host on an approval link → pending_approval, NO room, and the token DENIES them.
    assert {:ok, result} = CallStore.join_call_link(%{"link_id" => link.id, "user_id" => joiner})
    assert result.status == "pending_approval"
    assert result.is_host == false
    assert Map.get(result, :room) == nil
    assert result.call.id == hostcall.id

    assert {:ok, %{authorized: false}} =
             CallStore.call_participant?(%{"call_id" => hostcall.id, "user_id" => joiner})
  end

  @tag :postgres_integration
  test "approve_link_participant: host approves → joined → token authorizes" do
    host = new_user!()
    joiner = new_user!()
    {:ok, %{link: link}} =
      CallStore.create_call_link(%{"creator_id" => host, "type" => "voice", "require_approval" => true})

    {:ok, %{call: call}} = CallStore.join_call_link(%{"link_id" => link.id, "user_id" => host})
    {:ok, %{status: "pending_approval"}} =
      CallStore.join_call_link(%{"link_id" => link.id, "user_id" => joiner})

    assert {:ok, %{status: "joined", room: room, type: "voice"}} =
             CallStore.approve_link_participant(%{
               "call_id" => call.id,
               "actor_id" => host,
               "user_id" => joiner
             })

    assert String.starts_with?(room, "call-")
    assert {:ok, %{authorized: true}} =
             CallStore.call_participant?(%{"call_id" => call.id, "user_id" => joiner})
  end

  @tag :postgres_integration
  test "deny_link_participant: host denies → row removed → token still denies" do
    host = new_user!()
    joiner = new_user!()
    {:ok, %{link: link}} =
      CallStore.create_call_link(%{"creator_id" => host, "type" => "video", "require_approval" => true})

    {:ok, %{call: call}} = CallStore.join_call_link(%{"link_id" => link.id, "user_id" => host})
    {:ok, %{status: "pending_approval"}} =
      CallStore.join_call_link(%{"link_id" => link.id, "user_id" => joiner})

    assert {:ok, %{status: "denied"}} =
             CallStore.deny_link_participant(%{
               "call_id" => call.id,
               "actor_id" => host,
               "user_id" => joiner
             })

    assert {:ok, %{authorized: false}} =
             CallStore.call_participant?(%{"call_id" => call.id, "user_id" => joiner})

    # The denied user's row is gone.
    {:ok, %{participants: parts}} = CallStore.get_call_with_participants(%{"call_id" => call.id})
    refute Enum.any?(parts, &(&1.user_id == joiner))
  end

  @tag :postgres_integration
  test "approve/deny: a NON-host actor is forbidden" do
    host = new_user!()
    joiner = new_user!()
    stranger = new_user!()
    {:ok, %{link: link}} =
      CallStore.create_call_link(%{"creator_id" => host, "type" => "voice", "require_approval" => true})

    {:ok, %{call: call}} = CallStore.join_call_link(%{"link_id" => link.id, "user_id" => host})
    {:ok, _} = CallStore.join_call_link(%{"link_id" => link.id, "user_id" => joiner})

    assert {:error, :not_host} =
             CallStore.approve_link_participant(%{
               "call_id" => call.id,
               "actor_id" => stranger,
               "user_id" => joiner
             })

    assert {:error, :not_host} =
             CallStore.deny_link_participant(%{
               "call_id" => call.id,
               "actor_id" => stranger,
               "user_id" => joiner
             })
  end

  @tag :postgres_integration
  test "no-approval link: a non-host still joins directly (approval gate off)" do
    host = new_user!()
    joiner = new_user!()
    {:ok, %{link: link}} = CallStore.create_call_link(%{"creator_id" => host, "type" => "voice"})

    {:ok, %{call: call}} = CallStore.join_call_link(%{"link_id" => link.id, "user_id" => host})

    assert {:ok, %{status: "joined", is_host: false, room: room}} =
             CallStore.join_call_link(%{"link_id" => link.id, "user_id" => joiner})

    assert String.starts_with?(room, "call-")
    assert {:ok, %{authorized: true}} =
             CallStore.call_participant?(%{"call_id" => call.id, "user_id" => joiner})
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
