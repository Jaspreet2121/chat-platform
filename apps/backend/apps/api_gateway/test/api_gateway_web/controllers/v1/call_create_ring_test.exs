defmodule ApiGatewayWeb.V1.CallCreateRingTest do
  @moduledoc """
  POST /v1/calls must RING the callee — the gap this slice closes: create persisted a ringing call and handed
  the caller a room+token, but never broadcast `call:incoming` (so an SDK-initiated call rang nobody) and
  never armed a ring timeout (so it was never even marked missed).

  Stubs the Auth/Conversation/User clients, configures LiveKit (it signs a JWT locally — no network),
  subscribes to the endpoint's PubSub, and calls the controller action directly with the v1 assigns set —
  the same pattern as CallAcceptRejectTest. The socket invite path is proven unchanged by
  RealtimeGateway.CallSignalingTest (18 tests); THIS file proves the /v1 path emits the same ring.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.V1.CallController

  @caller "22222222-2222-4222-8222-222222222222"
  @callee "33333333-3333-4333-8333-333333333333"
  @app_id "55555555-5555-4555-8555-555555555555"
  @call_id "11111111-1111-4111-8111-111111111111"
  @room "call-11111111-1111-4111-8111-111111111111"

  defmodule AuthStub do
    # LOOKUP (resolve-only — create switched off resolve-or-create): "bob_ext" → the callee,
    # "self_ext" → the CALLER (the self-call case), anything else → :user_not_found (never creates).
    def lookup_external_user(%{"external_id" => "bob_ext"}),
      do: {:ok, %{user_id: "33333333-3333-4333-8333-333333333333"}}

    def lookup_external_user(%{"external_id" => "self_ext"}),
      do: {:ok, %{user_id: "22222222-2222-4222-8222-222222222222"}}

    def lookup_external_user(_), do: {:error, :user_not_found}
  end

  defmodule ConvStub do
    def start_link,
      do: Agent.start_link(fn -> %{status: "ringing", log: []} end, name: __MODULE__)

    def set_status(status), do: Agent.update(__MODULE__, &Map.put(&1, :status, status))
    def log, do: Agent.get(__MODULE__, & &1.log) |> Enum.reverse()

    def create_call(attrs) do
      record({:create, attrs})

      {:ok,
       %{
         id: "11111111-1111-4111-8111-111111111111",
         room_name: "call-11111111-1111-4111-8111-111111111111",
         caller_id: attrs["caller_id"],
         callee_id: attrs["callee_id"],
         type: attrs["type"],
         status: "ringing",
         conversation_id: nil,
         kind: "direct"
       }}
    end

    # The ring timeout re-reads the call to decide (the idempotence gate).
    def get_call(%{"call_id" => call_id}) do
      status = Agent.get(__MODULE__, & &1.status)

      {:ok,
       %{
         id: call_id,
         caller_id: "22222222-2222-4222-8222-222222222222",
         callee_id: "33333333-3333-4333-8333-333333333333",
         room_name: "call-11111111-1111-4111-8111-111111111111",
         status: status,
         conversation_id: nil,
         type: "voice",
         kind: "direct"
       }}
    end

    def mark_call_missed(attrs) do
      record({:missed, attrs})
      {:ok, %{id: attrs["call_id"], status: "missed"}}
    end

    defp record(entry), do: Agent.update(__MODULE__, fn s -> %{s | log: [entry | s.log]} end)
  end

  defmodule UserStub do
    def get_public_profile(_attrs), do: {:ok, %{display_name: "Alice V1"}}
  end

  defmodule RaisingUserStub do
    # resolve_caller must swallow this (internal rescue) — the ring still goes out with the fallback name.
    def get_public_profile(_attrs), do: raise("profile service down")
  end

  setup do
    start_supervised!(%{id: ConvStub, start: {ConvStub, :start_link, []}})

    prev = %{
      a: Application.get_env(:shared_infra, :auth_client_adapter),
      c: Application.get_env(:shared_infra, :conversation_client_adapter),
      u: Application.get_env(:shared_infra, :user_client_adapter),
      lk: Application.get_env(:shared_infra, :livekit),
      rt: Application.get_env(:realtime_gateway, :call_ring_timeout_ms)
    }

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)
    # LiveKitToken signs locally from this config — a real JWT, no network.
    Application.put_env(:shared_infra, :livekit, api_key: "lk-key", api_secret: "lk-secret-0123456789", url: "wss://lk.test")

    on_exit(fn ->
      restore(:shared_infra, :auth_client_adapter, prev.a)
      restore(:shared_infra, :conversation_client_adapter, prev.c)
      restore(:shared_infra, :user_client_adapter, prev.u)
      restore(:shared_infra, :livekit, prev.lk)
      restore(:realtime_gateway, :call_ring_timeout_ms, prev.rt)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, v), do: Application.put_env(app, key, v)

  defp v1_conn do
    :post
    |> conn("/v1/calls", %{})
    |> assign(:v1_app_id, @app_id)
    |> assign(:v1_actor, :end_user)
    |> assign(:v1_user_id, @caller)
  end

  defp create!(params) do
    CallController.create(v1_conn(), params)
  end

  test "create RINGS the callee: call:incoming on their user topic, exact socket payload shape" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@callee}")

    conn = create!(%{"callee_external_id" => "bob_ext", "type" => "voice"})

    # The caller's response contract is unchanged.
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["call_id"] == @call_id
    assert body["room"] == @room
    assert body["type"] == "voice"
    assert is_binary(body["token"]) and body["token"] != ""
    assert body["url"] == "wss://lk.test"

    # The callee rings — the EXACT payload the socket invite broadcasts (no fork of the wire shape).
    # No avatar in the stub profile → put_avatar omits the key; /v1 calls carry no conversation → nil.
    assert_receive %Phoenix.Socket.Broadcast{event: "call:incoming", payload: payload}, 1000

    assert payload == %{
             call_id: @call_id,
             room: @room,
             caller_id: @caller,
             caller_name: "Alice V1",
             type: "voice",
             conversation_id: nil
           }
  end

  test "a profile-service failure never fails the create — the ring still goes out with the fallback name" do
    Application.put_env(:shared_infra, :user_client_adapter, RaisingUserStub)
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@callee}")

    conn = create!(%{"callee_external_id" => "bob_ext", "type" => "voice"})
    assert conn.status == 200

    # resolve_caller rescues internally → short-id fallback, ring not lost.
    assert_receive %Phoenix.Socket.Broadcast{event: "call:incoming", payload: payload}, 1000
    assert payload.caller_name == "#" <> String.slice(@caller, 0, 8)
  end

  test "RING TIMEOUT: a call still ringing when the timer fires → missed + call:missed to BOTH parties" do
    # Shrink the detached timer for the test; ConvStub keeps reporting "ringing" so the re-check passes.
    Application.put_env(:realtime_gateway, :call_ring_timeout_ms, 60)
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@caller}")
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@callee}")

    assert create!(%{"callee_external_id" => "bob_ext", "type" => "voice"}).status == 200

    # Both parties are told the ring expired…
    assert_receive %Phoenix.Socket.Broadcast{event: "call:missed", payload: %{call_id: @call_id}}, 2000
    assert_receive %Phoenix.Socket.Broadcast{event: "call:missed", payload: %{call_id: @call_id}}, 2000

    # …and the SHARED missed-marking path ran (this is the fn whose CallStore transition emits the
    # call.missed webhook — proven against real Postgres in ConversationService.CallWebhooksTest).
    assert {:missed, %{"call_id" => @call_id}} in ConvStub.log()
  end

  test "RING TIMEOUT is idempotent: a call ACCEPTED before the timer fires → no-op (no missed, no broadcast)" do
    Application.put_env(:realtime_gateway, :call_ring_timeout_ms, 60)
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@caller}")

    assert create!(%{"callee_external_id" => "bob_ext", "type" => "voice"}).status == 200
    # The callee answers before the timer fires (the timer re-checks status on fire).
    ConvStub.set_status("accepted")

    refute_receive %Phoenix.Socket.Broadcast{event: "call:missed"}, 500
    refute Enum.any?(ConvStub.log(), &match?({:missed, _}, &1))
  end

  test "a BOGUS callee_external_id → 404: no user created, no call row, no ring (the lookup fix)" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@callee}")

    conn = create!(%{"callee_external_id" => "ghost_nobody", "type" => "voice"})

    # Previously this CREATED an inert user and "rang" nobody (resolve-or-create); now it is an opaque 404.
    assert conn.status == 404
    refute_receive %Phoenix.Socket.Broadcast{}, 200
    refute Enum.any?(ConvStub.log(), &match?({:create, _}, &1))
  end

  test "a self-call is still refused — and rings nobody" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@caller}")

    conn = create!(%{"callee_external_id" => "self_ext", "type" => "voice"})

    assert conn.status == 400
    refute_receive %Phoenix.Socket.Broadcast{}, 200
    refute Enum.any?(ConvStub.log(), &match?({:create, _}, &1))
  end
end
