defmodule ApiGatewayWeb.CallRejectTest do
  @moduledoc """
  The FIRST-PARTY closed-app decline endpoint: POST /api/v1/calls/:id/reject.

  Why it exists: with incoming-call FCM live, the callee's handset rings while the app (and its socket) is
  CLOSED, so tapping Decline has no socket to push `call:reject` over. Without this the decline is lost and the
  call resolves as a 35s server ring-TIMEOUT (missed). This session-authed, callee-only REST path resolves it
  as DECLINED instead — mark_call_declined + `call:rejected` to the caller + the SAME missed-call pill the
  socket decline writes (indistinguishable from a missed call).

  Stubs AuthClient (bearer token → user), ConversationClient (get_call + mark_call_declined, asserting the
  ATOMIC expected_status guard) and MessageClient (captures the pill), and subscribes to the endpoint PubSub
  for the caller broadcast — the same composition pattern as V1.CallAcceptRejectTest. The webhook itself is
  proven in ConversationService.CallWebhooksTest; here we prove the controller reaches (or doesn't reach) the
  shared transition + writes (or doesn't write) exactly one pill, with the right HTTP status.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.CallController

  # The test drives users by bearer TOKEN ("callee"/"caller"/"stranger"); AuthStub/CallStub own the concrete
  # ids. The test body itself only needs the caller (PubSub topic + pill sender), the call id, and the conv id.
  @call_id "11111111-1111-4111-8111-111111111111"
  @caller "22222222-2222-4222-8222-222222222222"
  @conv "66666666-6666-4666-8666-666666666666"

  defmodule AuthStub do
    @moduledoc false
    @caller "22222222-2222-4222-8222-222222222222"
    @callee "33333333-3333-4333-8333-333333333333"
    @stranger "44444444-4444-4444-8444-444444444444"
    @app_id "55555555-5555-4555-8555-555555555555"

    def current_session(%{"authorization" => "Bearer callee"}),
      do: {:ok, %{user_id: @callee, app_id: @app_id}}

    def current_session(%{"authorization" => "Bearer caller"}),
      do: {:ok, %{user_id: @caller, app_id: @app_id}}

    def current_session(%{"authorization" => "Bearer stranger"}),
      do: {:ok, %{user_id: @stranger, app_id: @app_id}}

    def current_session(_), do: {:error, :session_invalid}
  end

  # Plain module (no @behaviour) — the adapter dispatch resolves at runtime and only calls these two fns.
  defmodule CallStub do
    @moduledoc false
    @caller "22222222-2222-4222-8222-222222222222"
    @callee "33333333-3333-4333-8333-333333333333"
    @conv "66666666-6666-4666-8666-666666666666"

    def start_link,
      do:
        Agent.start_link(
          fn -> %{status: "ringing", kind: "direct", conflict: false, transitions: []} end,
          name: __MODULE__
        )

    def set_status(status), do: Agent.update(__MODULE__, &Map.put(&1, :status, status))
    def set_kind(kind), do: Agent.update(__MODULE__, &Map.put(&1, :kind, kind))

    # Simulate the atomic race: the fast-path read "ringing", but the row-locked transition finds it moved.
    def set_conflict(v), do: Agent.update(__MODULE__, &Map.put(&1, :conflict, v))
    # No participant rows in the direct-only stub: a group decline here is by a non-participant.
    def call_participant?(_attrs), do: {:ok, %{authorized: false}}
    def transitions, do: Agent.get(__MODULE__, & &1.transitions)

    def get_call(%{"call_id" => call_id}) do
      state = Agent.get(__MODULE__, & &1)

      {:ok,
       %{
         id: call_id,
         caller_id: @caller,
         callee_id: @callee,
         room_name: "room-abc",
         conversation_id: @conv,
         status: state.status,
         kind: state.kind,
         type: "voice"
       }}
    end

    def mark_call_declined(%{"call_id" => call_id} = attrs) do
      # The endpoint MUST request the atomic precondition — else a decline racing the 35s timeout writes a
      # SECOND pill. Asserting it here is the guard.
      "ringing" = attrs["expected_status"]

      if Agent.get(__MODULE__, & &1.conflict) do
        {:error, :call_conflict}
      else
        Agent.update(__MODULE__, fn s ->
          %{s | transitions: s.transitions ++ [{:declined, call_id}]}
        end)

        {:ok, %{id: call_id, status: "declined"}}
      end
    end
  end

  defmodule MissingCallStub do
    @moduledoc false
    def get_call(_attrs), do: {:error, :call_not_found}
    def mark_call_declined(_attrs), do: {:error, :call_not_found}
  end

  # Captures the pill write_missed_message performs; returns ok so its message_created fan-out proceeds.
  defmodule PillStub do
    @moduledoc false
    def create_message(attrs) do
      send(:call_reject_test, {:pill, attrs})
      {:ok, Map.put(attrs, "message_id", "pill_1")}
    end
  end

  setup do
    Process.register(self(), :call_reject_test)
    start_supervised!(%{id: CallStub, start: {CallStub, :start_link, []}})

    prev = %{
      conv: Application.get_env(:shared_infra, :conversation_client_adapter),
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      msg: Application.get_env(:shared_infra, :message_client_adapter)
    }

    Application.put_env(:shared_infra, :conversation_client_adapter, CallStub)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :message_client_adapter, PillStub)

    on_exit(fn ->
      restore(:conversation_client_adapter, prev.conv)
      restore(:auth_client_adapter, prev.auth)
      restore(:message_client_adapter, prev.msg)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  defp reject_conn(token) do
    :post
    |> conn("/api/v1/calls/#{@call_id}/reject", %{})
    |> put_req_header("authorization", "Bearer #{token}")
  end

  test "the CALLEE declines a ringing call → 200; caller gets call:rejected; the missed pill is written" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@caller}")

    conn = CallController.reject(reject_conn("callee"), %{"id" => @call_id})

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"call_id" => @call_id}

    # The caller's ring resolves as rejected …
    assert_receive %Phoenix.Socket.Broadcast{
                     topic: topic,
                     event: "call:rejected",
                     payload: %{call_id: @call_id}
                   },
                   1000

    assert topic == "user:#{@caller}"

    # … and the chat gets the SAME missed pill the socket decline writes: sender = caller, metadata "missed".
    assert_receive {:pill, attrs}, 1000
    assert attrs["message_type"] == "call"
    assert attrs["sender_user_id"] == @caller
    assert attrs["conversation_id"] == @conv
    assert attrs["metadata"]["status"] == "missed"

    assert CallStub.transitions() == [{:declined, @call_id}]
  end

  test "a NON-callee (the caller) → 403 forbidden; no transition, no pill, no broadcast" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@caller}")

    conn = CallController.reject(reject_conn("caller"), %{"id" => @call_id})

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "calls.forbidden"
    assert CallStub.transitions() == []
    refute_receive {:pill, _}, 150
    refute_receive %Phoenix.Socket.Broadcast{}, 150
  end

  test "a THIRD user → 403 forbidden" do
    conn = CallController.reject(reject_conn("stranger"), %{"id" => @call_id})
    assert conn.status == 403
    assert CallStub.transitions() == []
  end

  test "an unknown call → 404 not found" do
    Application.put_env(:shared_infra, :conversation_client_adapter, MissingCallStub)

    conn = CallController.reject(reject_conn("callee"), %{"id" => @call_id})

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "calls.not_found"
  end

  test "an already-TERMINAL call (the timeout won) → idempotent 200, NO transition, NO pill, NO broadcast" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@caller}")
    CallStub.set_status("missed")

    conn = CallController.reject(reject_conn("callee"), %{"id" => @call_id})

    # A decline arriving after the 35s timeout must never 500 and must never write a second pill.
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"call_id" => @call_id}
    assert CallStub.transitions() == []
    refute_receive {:pill, _}, 150
    refute_receive %Phoenix.Socket.Broadcast{}, 150
  end

  test "the ATOMIC race: get_call reads ringing but the locked transition conflicts → idempotent 200, no pill" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@caller}")
    CallStub.set_conflict(true)

    conn = CallController.reject(reject_conn("callee"), %{"id" => @call_id})

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"call_id" => @call_id}
    # :call_conflict → the timeout already handled it → no second pill, no caller broadcast.
    refute_receive {:pill, _}, 150
    refute_receive %Phoenix.Socket.Broadcast{}, 150
  end

  # 130-group: a group decline is NOT the callee's flow (there is no callee) — it is the caller's own
  # participant row. The direct-only stub here has no participant rows, so a group decline by a user
  # who is not a participant reads as 404 (never 403: a call id must not confirm its existence).
  test "a decline on a GROUP call by a NON-participant → 404, no transition" do
    CallStub.set_kind("group")
    conn = CallController.reject(reject_conn("callee"), %{"id" => @call_id})
    assert conn.status == 404
    assert CallStub.transitions() == []
  end

  # ---- 130-group: group decline and REST join ----------------------------------------------------

  defmodule GroupStub do
    @moduledoc false
    @caller "22222222-2222-4222-8222-222222222222"
    @member "33333333-3333-4333-8333-333333333333"
    @other "77777777-7777-4777-8777-777777777777"

    def start_link,
      do:
        Agent.start_link(
          fn -> %{status: "ringing", member_status: "invited", transitions: []} end,
          name: __MODULE__
        )

    def set_status(v), do: Agent.update(__MODULE__, &Map.put(&1, :status, v))
    def set_member_status(v), do: Agent.update(__MODULE__, &Map.put(&1, :member_status, v))
    def transitions, do: Agent.get(__MODULE__, & &1.transitions)

    def get_call(%{"call_id" => id}) do
      st = Agent.get(__MODULE__, & &1)

      {:ok,
       %{
         id: id,
         kind: "group",
         caller_id: @caller,
         callee_id: nil,
         room_name: "call-" <> id,
         conversation_id: "66666666-6666-4666-8666-666666666666",
         status: st.status,
         type: "voice"
       }}
    end

    # The REAL store shape: %{authorized: boolean} — participation is the caller's row.
    def call_participant?(%{"user_id" => uid}),
      do: {:ok, %{authorized: uid in [@caller, @member, @other]}}

    def get_call_with_participants(%{"call_id" => id}) do
      st = Agent.get(__MODULE__, & &1)

      {:ok,
       %{
         call: %{id: id, status: st.status},
         participants: [
           %{user_id: @caller, status: "joined"},
           %{user_id: @member, status: st.member_status},
           %{user_id: @other, status: "invited"}
         ]
       }}
    end

    def decline_group_call(%{"call_id" => id, "user_id" => uid}) do
      Agent.update(__MODULE__, fn s ->
        %{s | member_status: "declined", transitions: s.transitions ++ [{:declined, uid}]}
      end)

      {:ok,
       %{call: %{id: id, status: "ringing"}, participant: %{user_id: uid, status: "declined"}}}
    end

    def join_group_call(%{"call_id" => id, "user_id" => uid}) do
      Agent.update(__MODULE__, fn s ->
        %{
          s
          | member_status: "joined",
            status: "ongoing",
            transitions: s.transitions ++ [{:joined, uid}]
        }
      end)

      {:ok,
       %{
         call: %{id: id, status: "ongoing", room_name: "call-" <> id},
         participant: %{user_id: uid, status: "joined", joined_at: "2026-09-23T10:00:00Z"}
       }}
    end
  end

  defmodule GroupAuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer member"}),
      do: {:ok, %{user_id: "33333333-3333-4333-8333-333333333333", app_id: "app-1"}}

    def current_session(%{"authorization" => "Bearer stranger"}),
      do: {:ok, %{user_id: "44444444-4444-4444-8444-444444444444", app_id: "app-1"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  describe "group calls (130-group)" do
    setup do
      start_supervised!(%{id: GroupStub, start: {GroupStub, :start_link, []}})
      Application.put_env(:shared_infra, :conversation_client_adapter, GroupStub)
      Application.put_env(:shared_infra, :auth_client_adapter, GroupAuthStub)
      # The invited "other" member is who a participant_* broadcast must reach.
      Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:77777777-7777-4777-8777-777777777777")
      :ok
    end

    defp group_conn(verb, action, token) do
      verb
      |> conn("/api/v1/calls/#{@call_id}/#{action}", %{})
      |> put_req_header("authorization", "Bearer #{token}")
    end

    test "a PARTICIPANT declines a group call → 200; their row is declined; the others get participant_declined" do
      conn = CallController.reject(group_conn(:post, "reject", "member"), %{"id" => @call_id})
      assert conn.status == 200
      assert GroupStub.transitions() == [{:declined, "33333333-3333-4333-8333-333333333333"}]

      assert_receive %Phoenix.Socket.Broadcast{event: "call:participant_declined", payload: p},
                     1000

      assert p.user_id == "33333333-3333-4333-8333-333333333333"
    end

    test "a second decline is an idempotent 200 — nothing written, nothing broadcast again" do
      GroupStub.set_member_status("declined")
      conn = CallController.reject(group_conn(:post, "reject", "member"), %{"id" => @call_id})
      assert conn.status == 200
      assert GroupStub.transitions() == []
      refute_receive %Phoenix.Socket.Broadcast{event: "call:participant_declined"}, 200
    end

    test "a NON-participant's decline → 404, same as a call that does not exist" do
      conn = CallController.reject(group_conn(:post, "reject", "stranger"), %{"id" => @call_id})
      assert conn.status == 404
      assert GroupStub.transitions() == []
    end

    test "REST JOIN: a push-woken participant joins → 200 with the room; the others get participant_joined" do
      conn = CallController.join(group_conn(:post, "join", "member"), %{"id" => @call_id})
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["room"] == "call-" <> @call_id
      assert is_list(body["participants"])
      assert GroupStub.transitions() == [{:joined, "33333333-3333-4333-8333-333333333333"}]

      assert_receive %Phoenix.Socket.Broadcast{event: "call:participant_joined", payload: p}, 1000
      assert p.user_id == "33333333-3333-4333-8333-333333333333"
    end

    test "REST JOIN by a NON-participant → 404, no transition" do
      conn = CallController.join(group_conn(:post, "join", "stranger"), %{"id" => @call_id})
      assert conn.status == 404
      assert GroupStub.transitions() == []
    end
  end

  test "a missing/invalid session → 401" do
    conn = CallController.reject(reject_conn("nobody"), %{"id" => @call_id})
    assert conn.status == 401
  end
end
