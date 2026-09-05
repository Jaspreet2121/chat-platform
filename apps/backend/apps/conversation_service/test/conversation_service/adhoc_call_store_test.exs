defmodule ConversationService.AdhocCallStoreTest do
  @moduledoc """
  AD-HOC conversationless group calls (116) — the CallStore half, on real SQL.

  THE CONTRACT UNDER TEST, security-first: every target must exist, be active, live in the CALLER'S
  app, and have no block in either direction — checked in batch BEFORE any row exists, and any
  failure refuses the WHOLE invite with the single uniform `:invalid_targets`. Which target failed,
  and why, is never revealed: a partial ring (or a distinguishable error) is a block/existence
  oracle — send [victim, friend] and watch who rings.

  Also pinned: the NULL-conversation lifecycle (join/add/decline/leave/token-predicate all work off
  participant rows alone), and the REGRESSION guard that conversation-backed group calls still
  consult ensure_can_start — the adhoc rule deliberately has no settings to read, and routing group
  creates through it would silently void admins_only.
  """
  use ExUnit.Case, async: false

  alias ConversationService.CallStore
  alias ConversationService.Repo

  @tenant_zero "00000000-0000-0000-0000-000000000001"

  # --- 1. tenant + existence -----------------------------------------------------------------------

  @tag :postgres_integration
  test "CROSS-TENANT target refused — and indistinguishable from a nonexistent one" do
    caller = user!()
    same_app = user!()
    other_app = user_in_other_app!()
    ghost = Ecto.UUID.generate()

    cross = adhoc(caller, [same_app, other_app])
    missing = adhoc(caller, [same_app, ghost])

    assert {:error, :invalid_targets} = cross
    # THE ORACLE TEST: byte-identical tuples. If these ever diverge, the error becomes a probe for
    # whether an id exists in another tenant.
    assert cross == missing
  end

  @tag :postgres_integration
  test "an INACTIVE target refuses the whole invite" do
    caller = user!()
    fine = user!()
    suspended = user!()
    Repo.query!("UPDATE users_auth SET status = 'suspended' WHERE id = $1", [dump!(suspended)])

    assert {:error, :invalid_targets} = adhoc(caller, [fine, suspended])
  end

  # --- 2. blocks, BOTH directions, asserted separately ---------------------------------------------

  @tag :postgres_integration
  test "a target the CALLER has blocked refuses the invite (caller -> target direction)" do
    caller = user!()
    fine = user!()
    blocked = user!()
    block!(caller, blocked)

    assert {:error, :invalid_targets} = adhoc(caller, [fine, blocked])
  end

  @tag :postgres_integration
  test "a target who has blocked THE CALLER refuses the invite (target -> caller direction)" do
    caller = user!()
    fine = user!()
    blocker = user!()
    block!(blocker, caller)

    assert {:error, :invalid_targets} = adhoc(caller, [fine, blocker])
  end

  # --- 3. the uniform-error property across every refusal cause ------------------------------------

  @tag :postgres_integration
  test "nonexistent, cross-tenant and blocked (each direction) produce BYTE-IDENTICAL refusals" do
    caller = user!()
    fine = user!()
    blocked = user!()
    block!(caller, blocked)
    blocker = user!()
    block!(blocker, caller)

    refusals = [
      adhoc(caller, [fine, Ecto.UUID.generate()]),
      adhoc(caller, [fine, user_in_other_app!()]),
      adhoc(caller, [fine, blocked]),
      adhoc(caller, [fine, blocker])
    ]

    assert Enum.uniq(refusals) == [{:error, :invalid_targets}],
           "refusal causes are distinguishable — the error is an existence/block oracle: " <>
             inspect(Enum.uniq(refusals))
  end

  # --- 4. the cap ----------------------------------------------------------------------------------

  @tag :postgres_integration
  test "8 targets ring; 9 refuse — the no-shared-context primitive is bounded" do
    caller = user!()
    eight = for _ <- 1..8, do: user!()
    ninth = user!()

    assert {:ok, %{member_ids: member_ids}} = adhoc(caller, eight)
    assert length(member_ids) == 8

    assert {:error, :invalid_targets} = adhoc(caller, eight ++ [ninth])
  end

  # --- 7. the NULL-conversation lifecycle ----------------------------------------------------------

  @tag :postgres_integration
  test "create: kind adhoc, NO conversation, initiator joined, targets invited, ring list exact" do
    caller = user!()
    a = user!()
    b = user!()

    assert {:ok, %{call: call, participants: parts, member_ids: member_ids}} =
             adhoc(caller, [a, b])

    assert call.kind == "adhoc"
    assert is_nil(call.conversation_id)
    assert is_nil(call.callee_id)
    assert call.caller_id == caller
    assert call.status == "ringing"
    assert String.starts_with?(call.room_name, "call-")
    assert Enum.sort(member_ids) == Enum.sort([a, b])

    by_user = Map.new(parts, &{&1.user_id, &1.status})
    assert by_user == %{caller => "joined", a => "invited", b => "invited"}
  end

  @tag :postgres_integration
  test "JOIN works off the participant row alone (no conversation membership to consult)" do
    caller = user!()
    a = user!()
    {:ok, %{call: call}} = adhoc(caller, [a])

    assert {:ok, %{call: joined, participant: p}} =
             CallStore.join_group_call(%{"call_id" => call.id, "user_id" => a})

    assert joined.status == "ongoing"
    assert p.status == "joined"
  end

  @tag :postgres_integration
  test "a STRANGER (no participant row) cannot join, and the token predicate 403s them" do
    caller = user!()
    a = user!()
    stranger = user!()
    {:ok, %{call: call}} = adhoc(caller, [a])

    assert {:error, :not_a_member} =
             CallStore.join_group_call(%{"call_id" => call.id, "user_id" => stranger})

    assert {:ok, %{authorized: false}} =
             CallStore.call_participant?(%{"call_id" => call.id, "user_id" => stranger})

    assert {:ok, %{authorized: true}} =
             CallStore.call_participant?(%{"call_id" => call.id, "user_id" => a})
  end

  @tag :postgres_integration
  test "ADD by a joined participant runs the SAME per-target gate as create" do
    caller = user!()
    a = user!()
    {:ok, %{call: call}} = adhoc(caller, [a])
    {:ok, _} = CallStore.join_group_call(%{"call_id" => call.id, "user_id" => a})

    # A legitimate same-app target is added as invited.
    newcomer = user!()

    assert {:ok, %{added_user_id: ^newcomer}} =
             CallStore.add_call_participant(%{
               "call_id" => call.id,
               "actor_id" => a,
               "user_id" => newcomer
             })

    # A cross-tenant target refuses — this is where resolve_add_target's user_id tenant gap is
    # CLOSED for the adhoc kind.
    assert {:error, :invalid_targets} =
             CallStore.add_call_participant(%{
               "call_id" => call.id,
               "actor_id" => a,
               "user_id" => user_in_other_app!()
             })

    # A blocked-either-direction target refuses identically.
    hostile = user!()
    block!(hostile, a)

    assert {:error, :invalid_targets} =
             CallStore.add_call_participant(%{
               "call_id" => call.id,
               "actor_id" => a,
               "user_id" => hostile
             })

    # A STRANGER cannot act as the adder at all.
    outsider = user!()

    assert {:error, :call_add_forbidden} =
             CallStore.add_call_participant(%{
               "call_id" => call.id,
               "actor_id" => outsider,
               "user_id" => user!()
             })
  end

  @tag :postgres_integration
  test "DECLINE and LEAVE work with no conversation behind the call" do
    caller = user!()
    a = user!()
    b = user!()
    {:ok, %{call: call}} = adhoc(caller, [a, b])

    assert {:ok, _} = CallStore.decline_group_call(%{"call_id" => call.id, "user_id" => a})
    {:ok, _} = CallStore.join_group_call(%{"call_id" => call.id, "user_id" => b})
    assert {:ok, _} = CallStore.leave_group_call(%{"call_id" => call.id, "user_id" => b})
  end

  # --- 8. regression: the conversation-backed group rule is untouched ------------------------------

  @tag :postgres_integration
  test "kind=group STILL consults ensure_can_start — adhoc's no-settings bypass must not leak in" do
    owner = Ecto.UUID.generate()
    member = Ecto.UUID.generate()
    Enum.each([owner, member], &seed_user!(&1, @tenant_zero))

    {:ok, conv} =
      ConversationService.Conversations.create_conversation(%{
        "type" => "group",
        "title" => "Locked",
        "created_by" => owner,
        "participant_user_ids" => [member]
      })

    {:ok, _} =
      ConversationService.Participants.set_group_settings(%{
        "conversation_id" => conv.conversation_id,
        "actor_user_id" => owner,
        "only_admins_can_send" => false,
        "call_start_permission" => "admins_only"
      })

    assert {:error, :call_start_forbidden} =
             CallStore.create_group_call(%{
               "initiator_id" => member,
               "conversation_id" => conv.conversation_id,
               "type" => "voice"
             })
  end

  # --- 9. normalisation ----------------------------------------------------------------------------

  @tag :postgres_integration
  test "dupes collapse, self drops, and what remains is what rings" do
    caller = user!()
    a = user!()

    assert {:ok, %{member_ids: member_ids}} = adhoc(caller, [a, a, caller, a])
    assert member_ids == [a]
  end

  @tag :postgres_integration
  test "self-only, empty, non-UUID and non-list all refuse with the uniform code" do
    caller = user!()

    assert {:error, :invalid_targets} = adhoc(caller, [caller])
    assert {:error, :invalid_targets} = adhoc(caller, [])
    assert {:error, :invalid_targets} = adhoc(caller, ["not-a-uuid"])
    assert {:error, :invalid_targets} = adhoc(caller, "not-a-list")
  end

  # --- helpers -------------------------------------------------------------------------------------

  defp adhoc(caller, targets, type \\ "voice") do
    CallStore.create_adhoc_group_call(%{
      "initiator_id" => caller,
      "user_ids" => targets,
      "type" => type,
      "app_id" => @tenant_zero
    })
  end

  defp user! do
    id = Ecto.UUID.generate()
    seed_user!(id, @tenant_zero)
    id
  end

  # A REAL second tenant: its own apps row, its own user. The cross-tenant tests ring this user from
  # tenant zero and must be refused exactly like a nonexistent id.
  defp user_in_other_app! do
    app_id = Ecto.UUID.generate()

    n = System.unique_integer([:positive])

    Repo.query!(
      "INSERT INTO apps (id, name, slug) VALUES ($1, $2, $3)",
      [dump!(app_id), "adhoc-test-app-#{n}", "adhoc-test-#{n}"]
    )

    id = Ecto.UUID.generate()
    seed_user!(id, app_id)
    id
  end

  defp seed_user!(user_id, app_id) do
    Repo.query!(
      "INSERT INTO users_auth (id, email, status, app_id) VALUES ($1, $2, 'active', $3)",
      [
        dump!(user_id),
        "adhoc-#{System.unique_integer([:positive])}@example.test",
        dump!(app_id)
      ]
    )
  end

  defp block!(blocker, blocked) do
    Repo.query!(
      "INSERT INTO user_blocks (blocker_user_id, blocked_user_id) VALUES ($1, $2)",
      [dump!(blocker), dump!(blocked)]
    )
  end

  defp dump!(uuid), do: Ecto.UUID.dump!(uuid)

  setup do
    previous = Application.get_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:conversation_service, :conversation_persistence, true)

    start_repo!(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    on_exit(fn ->
      Application.put_env(:conversation_service, :conversation_persistence, previous)
    end)

    :ok
  end

  defp start_repo!(repo) do
    case repo.start_link() do
      {:ok, pid} -> Process.unlink(pid) && :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
