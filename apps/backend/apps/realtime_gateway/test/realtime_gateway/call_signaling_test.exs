defmodule RealtimeGateway.CallSignalingMockClient do
  @moduledoc """
  In-memory stand-in for the call surface of `SharedInfra.ConversationClient` (one ringing call at a time),
  backed by a named Agent. Records every call so tests can assert the store was driven; returns atom-keyed
  maps (like the in-process CallStore) which `CallSignaling.cget/2` reads. Not a full behaviour impl — the
  dispatcher resolves the adapter at runtime, so only the call functions the signaling path uses are here.
  """
  def start_link, do: Agent.start_link(fn -> %{call: nil, group: nil, log: []} end, name: __MODULE__)
  def reset, do: Agent.update(__MODULE__, fn _ -> %{call: nil, group: nil, log: []} end)
  def log, do: Agent.get(__MODULE__, & &1.log) |> Enum.reverse()
  def group_call, do: Agent.get(__MODULE__, &(&1.group && &1.group.call))

  # --- group calling (Phase 3) — mirrors CallStore's {:ok, %{call, participants, member_ids}} shapes ----
  # The conversation's members are seeded by the test via :group_members (the real fn reads the DB).
  def create_group_call(%{"initiator_id" => initiator} = attrs) do
    members = Application.get_env(:realtime_gateway, :group_members, [])

    if initiator not in members do
      # Mirror CallStore's membership gate so the signaling error-mapping is exercised.
      {:error, :not_a_member}
    else
      others = Enum.reject(members, &(&1 == initiator))

      call = %{
        id: "gcall_1",
        room_name: "groom_1",
        kind: "group",
        status: "ringing",
        caller_id: initiator,
        callee_id: nil,
        conversation_id: attrs["conversation_id"],
        type: attrs["type"]
      }

      parts =
        [%{call_id: "gcall_1", user_id: initiator, status: "joined", joined_at: "t0"}] ++
          Enum.map(others, &%{call_id: "gcall_1", user_id: &1, status: "invited", joined_at: nil})

      Agent.update(__MODULE__, fn s ->
        %{s | group: %{call: call, participants: parts}, log: [{:group_create, attrs} | s.log]}
      end)

      {:ok, %{call: call, participants: parts, member_ids: others}}
    end
  end

  def join_group_call(%{"user_id" => uid} = attrs) do
    Agent.get_and_update(__MODULE__, fn s ->
      g = s.group
      call = %{g.call | status: "ongoing"}

      parts =
        Enum.map(g.participants, fn p ->
          if p.user_id == uid, do: %{p | status: "joined", joined_at: "tj"}, else: p
        end)

      participant = Enum.find(parts, &(&1.user_id == uid))

      {{:ok, %{call: call, participant: participant}},
       %{s | group: %{call: call, participants: parts}, log: [{:group_join, attrs} | s.log]}}
    end)
  end

  def get_call_with_participants(_attrs) do
    case Agent.get(__MODULE__, & &1.group) do
      %{call: call, participants: parts} -> {:ok, %{call: call, participants: parts}}
      _ -> {:error, :call_not_found}
    end
  end

  def create_call(attrs) do
    call = %{
      id: "call_1",
      room_name: "room_1",
      status: "ringing",
      caller_id: attrs["caller_id"],
      callee_id: attrs["callee_id"],
      type: attrs["type"],
      conversation_id: attrs["conversation_id"]
    }

    Agent.update(__MODULE__, fn s -> %{s | call: call, log: [{:create, attrs} | s.log]} end)
    {:ok, call}
  end

  def get_call(%{"call_id" => id}) do
    case Agent.get(__MODULE__, & &1.call) do
      %{id: ^id} = call -> {:ok, call}
      _ -> {:error, :call_not_found}
    end
  end

  def mark_call_answered(attrs), do: transition(:answer, "accepted", attrs)
  def mark_call_declined(attrs), do: transition(:decline, "declined", attrs)
  def mark_call_missed(attrs), do: transition(:miss, "missed", attrs)
  def mark_call_ended(attrs), do: transition(:end, "ended", attrs)

  defp transition(op, status, attrs) do
    Agent.get_and_update(__MODULE__, fn s ->
      call = if s.call, do: %{s.call | status: status}, else: nil
      {{:ok, call}, %{s | call: call, log: [{op, attrs} | s.log]}}
    end)
  end
end

defmodule RealtimeGateway.CallCaptureEndpoint do
  @moduledoc "Fake channel endpoint: forwards every broadcast to the registered test pid."
  def broadcast(topic, event, payload) do
    case Application.get_env(:realtime_gateway, :call_test_pid) do
      pid when is_pid(pid) -> send(pid, {:broadcast, topic, event, payload})
      _ -> :ok
    end

    :ok
  end
end

defmodule RealtimeGateway.CallPillCaptureClient do
  @moduledoc """
  Captures the missed-call pill that `write_missed_message/2` writes via `SharedInfra.MessageClient`. Sends
  each `create_message` attrs to the test pid so a test can assert the pill's exact shape AND count (exactly
  one; none). Returns {:ok, response} so the pill's message_created fan-out proceeds.
  """
  def create_message(attrs) do
    case Application.get_env(:realtime_gateway, :call_test_pid) do
      pid when is_pid(pid) -> send(pid, {:pill, attrs})
      _ -> :ok
    end

    {:ok, Map.put(attrs, "message_id", "pill_1")}
  end
end

defmodule RealtimeGateway.CallSignalingStubs do
  @moduledoc "UserClient / MediaClient stand-ins for the caller-profile + avatar-presign path (no @behaviour)."

  @app "44444444-4444-4444-8444-444444444444"
  def app, do: @app

  # Same-app caller WITH an avatar asset. App-scoped on purpose: a call that forgot to thread app_id would
  # miss this clause and fall through to :profile_invalid — so the "resolves the name" assertion guards the bug.
  defmodule NamedProfile do
    @app "44444444-4444-4444-8444-444444444444"
    def get_public_profile(%{"user_id" => uid, "app_id" => @app}),
      do: {:ok, %{user_id: uid, display_name: "Ada Lovelace", avatar_media_id: "media-1"}}

    def get_public_profile(_), do: {:error, :profile_invalid}
  end

  # Same-app caller with NO avatar.
  defmodule NoAvatarProfile do
    @app "44444444-4444-4444-8444-444444444444"
    def get_public_profile(%{"user_id" => uid, "app_id" => @app}),
      do: {:ok, %{user_id: uid, display_name: "Ada Lovelace", avatar_media_id: nil}}

    def get_public_profile(_), do: {:error, :profile_invalid}
  end

  # Cross-tenant / unknown user → app-scoped lookup 404s.
  defmodule MissingProfile do
    def get_public_profile(_attrs), do: {:error, :profile_not_found}
  end

  defmodule MediaOk do
    def get_download_url(%{"app_id" => _app, "purpose" => "user_avatar"}),
      do: {:ok, %{media_id: "media-1", download_url: "https://minio.local/ada.png?signed=1"}}

    def get_download_url(_), do: {:error, :not_found}
  end

  defmodule MediaError do
    def get_download_url(_attrs), do: {:error, :media_unavailable}
  end
end

defmodule RealtimeGateway.CallSignalingTest do
  @moduledoc """
  Docker-free unit tests for the Phase-1 call ring control plane (`RealtimeGateway.CallSignaling`), driven
  directly with a fake socket + capture endpoint + mock conversation client — no DB, no Kafka (push stays
  off by default). Covers: invite persists + rings the callee; accept/reject/hangup transition + notify the
  right party; and ownership auth rejects a non-participant and the wrong role.
  """
  use ExUnit.Case, async: false

  alias RealtimeGateway.CallSignaling
  alias RealtimeGateway.CallSignalingMockClient, as: Mock
  alias RealtimeGateway.CallSignalingStubs

  @caller "11111111-1111-1111-1111-111111111111"
  @callee "22222222-2222-2222-2222-222222222222"
  @stranger "33333333-3333-3333-3333-333333333333"
  @app "44444444-4444-4444-8444-444444444444"
  @dm_conv "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"

  setup do
    start_supervised!(%{id: Mock, start: {Mock, :start_link, []}})
    Mock.reset()

    prev = Application.get_env(:shared_infra, :conversation_client_adapter)
    prev_user = Application.get_env(:shared_infra, :user_client_adapter)
    prev_media = Application.get_env(:shared_infra, :media_client_adapter)
    Application.put_env(:shared_infra, :conversation_client_adapter, Mock)
    Application.put_env(:realtime_gateway, :call_test_pid, self())

    on_exit(fn ->
      restore(:conversation_client_adapter, prev)
      restore(:user_client_adapter, prev_user)
      restore(:media_client_adapter, prev_media)
      Application.delete_env(:realtime_gateway, :call_test_pid)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  # Point the caller-profile + avatar lookups at the given stubs for this test.
  defp use_stubs(user_stub, media_stub) do
    Application.put_env(:shared_infra, :user_client_adapter, user_stub)
    Application.put_env(:shared_infra, :media_client_adapter, media_stub)
  end

  # Fake socket: CallSignaling touches `.assigns.current_user_id`, `.assigns.app_id`, and `.endpoint`.
  defp socket(user_id),
    do: %{assigns: %{current_user_id: user_id, app_id: @app}, endpoint: RealtimeGateway.CallCaptureEndpoint}

  defp invite! do
    assert {:reply, {:ok, %{call_id: call_id, room: room}}, _} =
             CallSignaling.handle_event(
               "call:invite",
               %{"callee_id" => @callee, "type" => "video"},
               socket(@caller)
             )

    # The invite rings the CALLEE over their user topic with the room + caller identity.
    assert_receive {:broadcast, topic, "call:incoming", payload}
    assert topic == "user:#{@callee}"
    assert payload.call_id == call_id
    assert payload.room == room
    assert payload.type == "video"
    assert payload.caller_id == @caller

    {call_id, room}
  end

  test "invite persists a ringing call and rings the callee" do
    {call_id, _room} = invite!()

    assert call_id == "call_1"
    assert [{:create, attrs} | _] = Mock.log()
    assert attrs["caller_id"] == @caller
    assert attrs["callee_id"] == @callee
    assert attrs["type"] == "video"
  end

  # ---- caller name + avatar on the ring (the app_id fix + Change 2) ----------------------------

  test "invite resolves the caller's display name (app-scoped profile) and presigns their avatar" do
    use_stubs(CallSignalingStubs.NamedProfile, CallSignalingStubs.MediaOk)

    assert {:reply, {:ok, _}, _} =
             CallSignaling.handle_event(
               "call:invite",
               %{"callee_id" => @callee, "type" => "voice"},
               socket(@caller)
             )

    assert_receive {:broadcast, "user:" <> _callee, "call:incoming", payload}
    assert payload.caller_name == "Ada Lovelace"
    assert payload.caller_avatar_url == "https://minio.local/ada.png?signed=1"
  end

  test "invite falls back to a short id for a cross-tenant / unknown caller, and omits the avatar" do
    use_stubs(CallSignalingStubs.MissingProfile, CallSignalingStubs.MediaOk)

    assert {:reply, {:ok, _}, _} =
             CallSignaling.handle_event(
               "call:invite",
               %{"callee_id" => @callee, "type" => "voice"},
               socket(@caller)
             )

    assert_receive {:broadcast, _topic, "call:incoming", payload}
    # short(@caller) — "#" <> first 8 chars. Never crashes the ring.
    assert payload.caller_name == "#" <> String.slice(@caller, 0, 8)
    refute Map.has_key?(payload, :caller_avatar_url)
  end

  test "invite omits caller_avatar_url when the caller has no avatar (name still resolved)" do
    use_stubs(CallSignalingStubs.NoAvatarProfile, CallSignalingStubs.MediaOk)

    assert {:reply, {:ok, _}, _} =
             CallSignaling.handle_event(
               "call:invite",
               %{"callee_id" => @callee, "type" => "voice"},
               socket(@caller)
             )

    assert_receive {:broadcast, _topic, "call:incoming", payload}
    assert payload.caller_name == "Ada Lovelace"
    refute Map.has_key?(payload, :caller_avatar_url)
  end

  test "a media error while presigning the avatar still rings; the avatar is simply absent" do
    use_stubs(CallSignalingStubs.NamedProfile, CallSignalingStubs.MediaError)

    assert {:reply, {:ok, _}, _} =
             CallSignaling.handle_event(
               "call:invite",
               %{"callee_id" => @callee, "type" => "voice"},
               socket(@caller)
             )

    # The ring is NOT lost — a media hiccup must never block a call.
    assert_receive {:broadcast, "user:#{@callee}", "call:incoming", payload}
    assert payload.caller_name == "Ada Lovelace"
    refute Map.has_key?(payload, :caller_avatar_url)
  end

  test "inviting yourself is rejected without persisting" do
    assert {:reply, {:error, %{code: "call.invalid_callee"}}, _} =
             CallSignaling.handle_event(
               "call:invite",
               %{"callee_id" => @caller, "type" => "voice"},
               socket(@caller)
             )

    assert Mock.log() == []
  end

  test "callee accept transitions to accepted and notifies the caller with the room" do
    {call_id, room} = invite!()

    assert {:reply, {:ok, %{call_id: ^call_id}}, _} =
             CallSignaling.handle_event("call:accept", %{"call_id" => call_id}, socket(@callee))

    assert_receive {:broadcast, "user:" <> caller, "call:accepted", payload}
    assert caller == @caller
    assert payload.room == room
    assert Enum.any?(Mock.log(), &match?({:answer, _}, &1))
  end

  test "callee reject transitions to declined and notifies the caller" do
    {call_id, _room} = invite!()

    assert {:reply, {:ok, _}, _} =
             CallSignaling.handle_event("call:reject", %{"call_id" => call_id}, socket(@callee))

    assert_receive {:broadcast, "user:" <> caller, "call:rejected", %{call_id: ^call_id}}
    assert caller == @caller
    assert Enum.any?(Mock.log(), &match?({:decline, _}, &1))
  end

  # ---- FIX 1: a decline writes the SAME missed pill a cancel/timeout writes (WhatsApp semantics — a
  # declined call is indistinguishable from a missed one; the caller must not learn they were declined) ----
  describe "decline writes the missed-call pill" do
    setup do
      prev = Application.get_env(:shared_infra, :message_client_adapter)
      Application.put_env(:shared_infra, :message_client_adapter, RealtimeGateway.CallPillCaptureClient)
      on_exit(fn -> restore(:message_client_adapter, prev) end)
      :ok
    end

    # A first-party call carries a conversation_id (unlike /v1). Seed one directly so write_missed_message
    # doesn't skip (it no-ops for a conversation-less call).
    defp seed_dm_call do
      Mock.create_call(%{
        "caller_id" => @caller,
        "callee_id" => @callee,
        "type" => "voice",
        "conversation_id" => @dm_conv
      })
    end

    test "reject writes EXACTLY ONE missed pill — same body + metadata status as a missed call" do
      seed_dm_call()

      assert {:reply, {:ok, _}, _} =
               CallSignaling.handle_event("call:reject", %{"call_id" => "call_1"}, socket(@callee))

      # The caller is told the call is off …
      assert_receive {:broadcast, "user:#{@caller}", "call:rejected", %{call_id: "call_1"}}

      # … and the chat gets a pill IDENTICAL to a missed call's: sender = caller, type "call", body + metadata
      # status "missed". The client can't tell a decline from a miss.
      assert_receive {:pill, attrs}
      assert attrs["message_type"] == "call"
      assert attrs["sender_user_id"] == @caller
      assert attrs["conversation_id"] == @dm_conv
      assert attrs["body"] == "Missed voice call"
      assert attrs["metadata"]["status"] == "missed"
      assert attrs["metadata"]["call_type"] == "voice"

      # Exactly one — never a second pill.
      refute_receive {:pill, _}, 100

      # It fans out as an ordinary message_created (open clients append it live).
      assert_receive {:broadcast, "conversation:#{@dm_conv}", "message_created", _}
    end

    test "a ring-timeout AFTER a reject writes NO second pill (the double-write guarantee)" do
      seed_dm_call()

      assert {:reply, {:ok, _}, _} =
               CallSignaling.handle_event("call:reject", %{"call_id" => "call_1"}, socket(@callee))

      assert_receive {:pill, _}
      flush_broadcasts()

      # The 35s timer fires late. mark_call_declined already moved the call to "declined", so ring_timeout's
      # status re-check (only writes when status == "ringing") makes it a no-op — no mark_missed, no pill.
      assert :ok = CallSignaling.ring_timeout("call_1", RealtimeGateway.CallCaptureEndpoint)

      refute_receive {:pill, _}, 150
      refute Enum.any?(Mock.log(), &match?({:miss, _}, &1))
    end

    test "cancel still writes exactly one missed pill (the reference path is unchanged)" do
      seed_dm_call()

      assert {:reply, {:ok, _}, _} =
               CallSignaling.handle_event("call:cancel", %{"call_id" => "call_1"}, socket(@caller))

      assert_receive {:pill, attrs}
      assert attrs["metadata"]["status"] == "missed"
      refute_receive {:pill, _}, 100
    end
  end

  test "caller hangup notifies the OTHER party (callee)" do
    {call_id, _room} = invite!()

    assert {:reply, {:ok, _}, _} =
             CallSignaling.handle_event("call:hangup", %{"call_id" => call_id}, socket(@caller))

    assert_receive {:broadcast, "user:" <> other, "call:ended", %{call_id: ^call_id}}
    assert other == @callee
    assert Enum.any?(Mock.log(), &match?({:end, _}, &1))
  end

  test "a non-participant cannot accept (ownership auth → call.forbidden)" do
    {call_id, _room} = invite!()

    assert {:reply, {:error, %{code: "call.forbidden"}}, _} =
             CallSignaling.handle_event("call:accept", %{"call_id" => call_id}, socket(@stranger))

    # No transition happened.
    refute Enum.any?(Mock.log(), &match?({:answer, _}, &1))
  end

  test "the caller cannot accept their own call (accept is callee-only)" do
    {call_id, _room} = invite!()

    assert {:reply, {:error, %{code: "call.forbidden"}}, _} =
             CallSignaling.handle_event("call:accept", %{"call_id" => call_id}, socket(@caller))
  end

  test "acting on an unknown call id → call.not_found" do
    assert {:reply, {:error, %{code: "call.not_found"}}, _} =
             CallSignaling.handle_event("call:hangup", %{"call_id" => "nope"}, socket(@caller))
  end

  test "an unknown call:* event → call.invalid_event" do
    assert {:reply, {:error, %{code: "call.invalid_event"}}, _} =
             CallSignaling.handle_event("call:teleport", %{}, socket(@caller))
  end

  # ---- group calling (Phase 3) ------------------------------------------------------------------
  @owner "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  @m1 "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
  @m2 "cccccccc-cccc-cccc-cccc-cccccccccccc"
  @conv "dddddddd-dddd-dddd-dddd-dddddddddddd"

  defp seed_group_members(ids) do
    Application.put_env(:realtime_gateway, :group_members, ids)
    on_exit(fn -> Application.delete_env(:realtime_gateway, :group_members) end)
  end

  defp flush_broadcasts do
    receive do
      {:broadcast, _topic, _event, _payload} -> flush_broadcasts()
    after
      0 -> :ok
    end
  end

  test "call:group_invite fans call:group_incoming to every OTHER member (not self) + replies with room" do
    seed_group_members([@owner, @m1, @m2])

    assert {:reply, {:ok, %{call_id: call_id, room: room, participants: parts}}, _} =
             CallSignaling.handle_event(
               "call:group_invite",
               %{"conversation_id" => @conv, "type" => "video"},
               socket(@owner)
             )

    # Rings BOTH other members over their user topics — never the initiator.
    assert_receive {:broadcast, "user:" <> u1, "call:group_incoming", p1}
    assert_receive {:broadcast, "user:" <> u2, "call:group_incoming", p2}
    assert Enum.sort([u1, u2]) == Enum.sort([@m1, @m2])
    refute_receive {:broadcast, "user:" <> @owner, "call:group_incoming", _}

    assert p1.call_id == call_id
    assert p1.room == room
    assert p1.caller_id == @owner
    assert p1.type == "video"
    assert p1.conversation_id == @conv
    assert is_list(p2.participants)

    assert length(parts) == 3
    assert Enum.any?(Mock.log(), &match?({:group_create, _}, &1))
  end

  test "call:group_incoming carries the initiator's name + presigned avatar" do
    seed_group_members([@owner, @m1, @m2])
    use_stubs(CallSignalingStubs.NamedProfile, CallSignalingStubs.MediaOk)

    assert {:reply, {:ok, _}, _} =
             CallSignaling.handle_event(
               "call:group_invite",
               %{"conversation_id" => @conv, "type" => "voice"},
               socket(@owner)
             )

    assert_receive {:broadcast, "user:" <> _u1, "call:group_incoming", p1}
    assert p1.caller_name == "Ada Lovelace"
    assert p1.caller_avatar_url == "https://minio.local/ada.png?signed=1"
  end

  test "call:group_incoming still rings (avatar absent) when the presign errors" do
    seed_group_members([@owner, @m1, @m2])
    use_stubs(CallSignalingStubs.NamedProfile, CallSignalingStubs.MediaError)

    assert {:reply, {:ok, _}, _} =
             CallSignaling.handle_event(
               "call:group_invite",
               %{"conversation_id" => @conv, "type" => "voice"},
               socket(@owner)
             )

    assert_receive {:broadcast, "user:" <> _u1, "call:group_incoming", p1}
    assert p1.caller_name == "Ada Lovelace"
    refute Map.has_key?(p1, :caller_avatar_url)
  end

  test "call:group_join flips the call to ongoing and notifies the OTHER participants" do
    seed_group_members([@owner, @m1, @m2])

    {:reply, {:ok, %{call_id: call_id}}, _} =
      CallSignaling.handle_event(
        "call:group_invite",
        %{"conversation_id" => @conv, "type" => "voice"},
        socket(@owner)
      )

    flush_broadcasts()

    assert {:reply, {:ok, %{call_id: ^call_id, room: room}}, _} =
             CallSignaling.handle_event("call:group_join", %{"call_id" => call_id}, socket(@m1))

    assert is_binary(room)
    # The store flipped ringing → ongoing on the late join.
    assert Mock.group_call().status == "ongoing"

    # Everyone EXCEPT the joiner is told they joined.
    assert_receive {:broadcast, "user:" <> a, "call:participant_joined", jp}
    assert_receive {:broadcast, "user:" <> b, "call:participant_joined", _}
    assert Enum.sort([a, b]) == Enum.sort([@owner, @m2])
    assert jp.user_id == @m1
    refute_receive {:broadcast, "user:" <> @m1, "call:participant_joined", _}
  end

  test "starting a group call in a conversation you're not a member of → call.forbidden" do
    seed_group_members([@m1, @m2])

    assert {:reply, {:error, %{code: "call.forbidden"}}, _} =
             CallSignaling.handle_event(
               "call:group_invite",
               %{"conversation_id" => @conv, "type" => "voice"},
               socket(@stranger)
             )
  end
end
