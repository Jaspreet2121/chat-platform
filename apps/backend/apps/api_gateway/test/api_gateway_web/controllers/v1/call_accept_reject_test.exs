defmodule ApiGatewayWeb.V1.CallAcceptRejectTest do
  @moduledoc """
  The /v1 callee-answer path: authorization (callee-ONLY), the status guard (can't answer a call that isn't
  ringing — which would un-end it AND re-emit the webhook), and the caller notification.

  Stubs the ConversationClient and subscribes to the endpoint's PubSub, calling the controller action
  directly with the v1 assigns set (bypassing V1Auth) — the same pattern as MessageControllerBroadcastTest.

  The WEBHOOK itself is not asserted here: the controller calls `ConversationClient.mark_call_answered` /
  `mark_call_declined`, and ConversationService.CallWebhooksTest proves (against real Postgres) that those
  exact functions emit `call.started` / `call.declined` atomically and tenant-scoped. This test proves the
  controller reaches (or, on a guard failure, does NOT reach) those functions — the composition.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.V1.CallController

  @call_id "11111111-1111-4111-8111-111111111111"
  @caller "22222222-2222-4222-8222-222222222222"
  @callee "33333333-3333-4333-8333-333333333333"
  @stranger "44444444-4444-4444-8444-444444444444"
  @app_id "55555555-5555-4555-8555-555555555555"
  @room "room-abc"

  defmodule CallStub do
    @moduledoc false
    @behaviour SharedInfra.ConversationClient

    def start_link,
      do:
        Agent.start_link(
          fn -> %{status: "ringing", kind: "direct", transitions: [], conflict: false} end,
          name: __MODULE__
        )

    def set_status(status), do: Agent.update(__MODULE__, &Map.put(&1, :status, status))
    def set_kind(kind), do: Agent.update(__MODULE__, &Map.put(&1, :kind, kind))
    # Simulate the atomic race: the fast-path read "ringing", but the row-locked transition finds it moved.
    def set_conflict(v), do: Agent.update(__MODULE__, &Map.put(&1, :conflict, v))
    def transitions, do: Agent.get(__MODULE__, & &1.transitions)

    @impl true
    def get_call(%{"call_id" => call_id}) do
      state = Agent.get(__MODULE__, & &1)

      {:ok,
       %{
         id: call_id,
         caller_id: "22222222-2222-4222-8222-222222222222",
         callee_id: "33333333-3333-4333-8333-333333333333",
         room_name: "room-abc",
         status: state.status,
         kind: state.kind,
         type: "voice"
       }}
    end

    @impl true
    def mark_call_answered(%{"call_id" => call_id} = attrs) do
      # The /v1 path MUST request the atomic precondition — assert it does (else the race stays open).
      "ringing" = attrs["expected_status"]

      if Agent.get(__MODULE__, & &1.conflict) do
        {:error, :call_conflict}
      else
        record(:answered, call_id)
        {:ok, %{id: call_id, status: "accepted"}}
      end
    end

    @impl true
    def mark_call_declined(%{"call_id" => call_id} = attrs) do
      "ringing" = attrs["expected_status"]

      if Agent.get(__MODULE__, & &1.conflict) do
        {:error, :call_conflict}
      else
        record(:declined, call_id)
        {:ok, %{id: call_id, status: "declined"}}
      end
    end

    defp record(kind, call_id),
      do: Agent.update(__MODULE__, fn s -> %{s | transitions: s.transitions ++ [{kind, call_id}]} end)
  end

  defmodule MissingCallStub do
    @moduledoc false
    @behaviour SharedInfra.ConversationClient
    @impl true
    def get_call(_attrs), do: {:error, :call_not_found}
    @impl true
    def mark_call_answered(_attrs), do: {:error, :call_not_found}
    @impl true
    def mark_call_declined(_attrs), do: {:error, :call_not_found}
  end

  setup do
    start_supervised!(%{id: CallStub, start: {CallStub, :start_link, []}})
    prev = Application.get_env(:shared_infra, :conversation_client_adapter)
    Application.put_env(:shared_infra, :conversation_client_adapter, CallStub)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:shared_infra, :conversation_client_adapter, prev),
        else: Application.delete_env(:shared_infra, :conversation_client_adapter)
    end)

    :ok
  end

  # A conn as V1Auth would leave it for the given acting end-user.
  defp v1_conn(user_id) do
    :post
    |> conn("/v1/calls/#{@call_id}/accept", %{})
    |> Map.put(:params, %{"id" => @call_id})
    |> assign(:v1_app_id, @app_id)
    |> assign(:v1_actor, :end_user)
    |> assign(:v1_user_id, user_id)
  end

  # --- accept ---

  test "the CALLEE accepts a ringing call → accepted; caller gets call:accepted with the room" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@caller}")

    conn = CallController.accept(v1_conn(@callee), %{"id" => @call_id})

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"call_id" => @call_id, "room" => @room, "status" => "accepted"}

    # The caller's ring resolves off this frame, with the room to join.
    assert_receive %Phoenix.Socket.Broadcast{
                     topic: topic,
                     event: "call:accepted",
                     payload: %{call_id: @call_id, room: @room}
                   },
                   1000

    assert topic == "user:#{@caller}"
    # And the shared transition fired (this is the fn that emits call.started, per CallWebhooksTest).
    assert CallStub.transitions() == [{:answered, @call_id}]
  end

  test "a NON-callee (the caller) accepting → 404, status unchanged, NO transition, NO broadcast" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@caller}")

    # The caller trying to accept their own call is not the callee.
    conn = CallController.accept(v1_conn(@caller), %{"id" => @call_id})

    assert conn.status == 404
    # Never transitioned → no un-answer, no webhook.
    assert CallStub.transitions() == []
    refute_receive %Phoenix.Socket.Broadcast{}, 200
  end

  test "a THIRD user accepting → 404 (the callee comparison is the tenant seal)" do
    conn = CallController.accept(v1_conn(@stranger), %{"id" => @call_id})
    assert conn.status == 404
    assert CallStub.transitions() == []
  end

  test "accepting an already-ENDED call → 409, does NOT un-end it (no transition, no broadcast)" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@caller}")
    CallStub.set_status("ended")

    conn = CallController.accept(v1_conn(@callee), %{"id" => @call_id})

    assert conn.status == 409
    # The guard prevented the transition — the call stays ended and no second call.started is emitted.
    assert CallStub.transitions() == []
    refute_receive %Phoenix.Socket.Broadcast{}, 200
  end

  test "accepting an already-ACCEPTED call → 409 (idempotency guard; no re-emit)" do
    CallStub.set_status("accepted")
    conn = CallController.accept(v1_conn(@callee), %{"id" => @call_id})
    assert conn.status == 409
    assert CallStub.transitions() == []
  end

  test "the ATOMIC race: fast-path reads ringing but the locked transition conflicts → 409, no broadcast" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@caller}")
    # get_call still says "ringing" (the fast-path passes), but the row-locked transition lost the race.
    CallStub.set_conflict(true)

    conn = CallController.accept(v1_conn(@callee), %{"id" => @call_id})

    assert conn.status == 409
    # The transition returned :call_conflict → nothing committed → no caller broadcast.
    assert CallStub.transitions() == []
    refute_receive %Phoenix.Socket.Broadcast{}, 200
  end

  test "accept on a GROUP call → 404 (accept/reject are direct-call verbs)" do
    CallStub.set_kind("group")
    conn = CallController.accept(v1_conn(@callee), %{"id" => @call_id})
    assert conn.status == 404
    assert CallStub.transitions() == []
  end

  test "an app-actor (no end-user) → 403 end_user_only" do
    conn =
      :post
      |> conn("/v1/calls/#{@call_id}/accept", %{})
      |> assign(:v1_app_id, @app_id)
      |> assign(:v1_actor, :app)

    conn = CallController.accept(conn, %{"id" => @call_id})
    assert conn.status == 403
    assert CallStub.transitions() == []
  end

  test "a missing call (get_call → not found) → 404" do
    # Redefine get_call to miss by pointing the adapter at a stub that errors.
    Application.put_env(:shared_infra, :conversation_client_adapter, MissingCallStub)
    on_exit(fn -> Application.put_env(:shared_infra, :conversation_client_adapter, CallStub) end)

    conn = CallController.accept(v1_conn(@callee), %{"id" => @call_id})
    assert conn.status == 404
  end

  # --- reject ---

  test "the CALLEE rejects a ringing call → declined; caller gets call:rejected (no room)" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@caller}")

    conn = CallController.reject(v1_conn(@callee), %{"id" => @call_id})

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"call_id" => @call_id, "status" => "declined"}

    assert_receive %Phoenix.Socket.Broadcast{event: "call:rejected", payload: payload}, 1000
    assert payload == %{call_id: @call_id}
    # No room leaks on a reject.
    refute Map.has_key?(payload, :room)
    assert CallStub.transitions() == [{:declined, @call_id}]
  end

  test "a NON-callee rejecting → 404, no transition" do
    conn = CallController.reject(v1_conn(@stranger), %{"id" => @call_id})
    assert conn.status == 404
    assert CallStub.transitions() == []
  end
end
