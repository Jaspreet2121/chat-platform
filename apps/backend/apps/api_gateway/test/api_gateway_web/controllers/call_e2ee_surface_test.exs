defmodule ApiGatewayWeb.CallE2eeSurfaceTest do
  @moduledoc """
  The gateway surfaces for E2EE calls (111 / E2EE_FRAME.md §calls).

  `GET /api/v1/calls/:id` exists BECAUSE of E2EE: the incoming-call push is data-only and small (it
  must fit inside the 35s ring window and FCM's data cap), so the sealed key envelopes cannot ride
  it. A backgrounded callee wakes on the push and fetches the call here to find the envelope
  addressed to its own device. These tests pin who may read it, what it carries while ringing, and
  that a finished call yields no key material.

  No DB: the conversation client is stubbed, so this is purely the gateway's contract.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.CallController

  @caller "11111111-1111-1111-1111-111111111111"
  @callee "22222222-2222-2222-2222-222222222222"
  @stranger "33333333-3333-3333-3333-333333333333"
  @call_id "44444444-4444-4444-8444-444444444444"

  @offer %{
    "v" => 1,
    "sender_device_id" => "caller-dev",
    "envelopes" => [
      %{"device_id" => "callee-dev", "envelope_b64" => "c2VhbGVk"},
      %{"device_id" => "caller-dev-2", "envelope_b64" => "c2VhbGVkMg=="}
    ]
  }

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer " <> user}),
      do: {:ok, %{user_id: user, app_id: "app-1"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule UserStub do
    @moduledoc false
    def get_public_profile(%{"user_id" => id}), do: {:ok, %{user_id: id, display_name: "Peer"}}
    def get_public_profile(_), do: {:error, :profile_not_found}
    def get_privacy(_), do: {:ok, %{profile_photo_visibility: "everyone"}}
  end

  # A call row, shaped exactly as CallStore.response/1 returns it.
  defp call_row(over \\ %{}) do
    Map.merge(
      %{
        id: @call_id,
        room_name: "call-" <> @call_id,
        kind: "direct",
        app_id: "app-1",
        caller_id: @caller,
        callee_id: @callee,
        conversation_id: nil,
        type: "voice",
        status: "ringing",
        created_at: "2026-08-27T10:00:00Z",
        answered_at: nil,
        ended_at: nil,
        duration_seconds: nil,
        e2ee: true,
        e2ee_accepted: nil,
        e2ee_offer: @offer
      },
      over
    )
  end

  defp conversation_stub(row) do
    module = String.to_atom("Elixir.CallE2eeConvStub#{System.unique_integer([:positive])}")

    contents =
      quote do
        def get_call(%{"call_id" => _}), do: {:ok, unquote(Macro.escape(row))}
        def call_participant?(_), do: {:ok, %{participant: false}}

        def list_calls_for_user(%{"user_id" => _}),
          do: {:ok, %{calls: [unquote(Macro.escape(row))]}}
      end

    Module.create(module, contents, Macro.Env.location(__ENV__))
    Application.put_env(:shared_infra, :conversation_client_adapter, module)
    module
  end

  setup do
    previous = %{
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      conv: Application.get_env(:shared_infra, :conversation_client_adapter),
      user: Application.get_env(:shared_infra, :user_client_adapter)
    }

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)

    on_exit(fn ->
      for {key, value} <- [
            auth_client_adapter: previous.auth,
            conversation_client_adapter: previous.conv,
            user_client_adapter: previous.user
          ] do
        if value,
          do: Application.put_env(:shared_infra, key, value),
          else: Application.delete_env(:shared_infra, key)
      end
    end)

    :ok
  end

  defp get_state(user_id, row) do
    conversation_stub(row)

    :get
    |> conn("/api/v1/calls/" <> @call_id)
    |> put_req_header("authorization", "Bearer " <> user_id)
    |> CallController.show(%{"id" => @call_id})
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  describe "GET /api/v1/calls/:id — the push-woken callee's fetch" do
    test "the CALLEE gets the call state including the sealed offer, and can find its own envelope" do
      conn = get_state(@callee, call_row())
      assert conn.status == 200

      b = body(conn)
      assert b["id"] == @call_id
      # The room, so it can actually join after answering.
      assert b["room_name"] == "call-" <> @call_id
      assert b["status"] == "ringing"
      assert b["e2ee"] == true

      # THE POINT OF THIS ENDPOINT: the envelope addressed to this device is here.
      assert b["e2ee_offer"]["v"] == 1
      mine = Enum.find(b["e2ee_offer"]["envelopes"], &(&1["device_id"] == "callee-dev"))
      assert mine["envelope_b64"] == "c2VhbGVk"
    end

    test "the CALLER may also read it (its own self-copy envelope lives here too)" do
      conn = get_state(@caller, call_row())
      assert conn.status == 200
      assert body(conn)["e2ee_offer"]["envelopes"] |> length() == 2
    end

    test "a STRANGER gets 404 — a call id must not confirm its own existence" do
      conn = get_state(@stranger, call_row())
      assert conn.status == 404
      assert body(conn)["error"]["code"] == "calls.not_found"
      # And absolutely no key material leaked on the way out.
      refute conn.resp_body =~ "envelope_b64"
    end

    test "no session → 401" do
      conversation_stub(call_row())

      conn =
        :get
        |> conn("/api/v1/calls/" <> @call_id)
        |> CallController.show(%{"id" => @call_id})

      assert conn.status == 401
    end

    test "an ENDED call carries the booleans but NO envelopes — the key died with the call" do
      ended =
        call_row(%{
          status: "ended",
          ended_at: "2026-08-27T10:05:00Z",
          answered_at: "2026-08-27T10:00:30Z",
          e2ee_accepted: true,
          # The store scrubbed it on the terminal transition.
          e2ee_offer: nil
        })

      conn = get_state(@callee, ended)
      assert conn.status == 200

      b = body(conn)
      assert is_nil(b["e2ee_offer"])
      # ...but the durable bits survive, so history can still draw the lock.
      assert b["e2ee"] == true
      assert b["e2ee_accepted"] == true
    end

    test "a NON-E2EE call reads cleanly: booleans present and false/nil, no offer" do
      plain = call_row(%{e2ee: false, e2ee_accepted: nil, e2ee_offer: nil})

      b = body(get_state(@callee, plain))
      assert b["e2ee"] == false
      assert is_nil(b["e2ee_accepted"])
      assert is_nil(b["e2ee_offer"])
    end
  end

  describe "call history exposes the lock" do
    test "a past E2EE call carries e2ee + the agreed mode" do
      row =
        call_row(%{
          status: "ended",
          answered_at: "2026-08-27T10:00:30Z",
          ended_at: "2026-08-27T10:05:00Z",
          e2ee_accepted: true,
          e2ee_offer: nil
        })

      conversation_stub(row)

      conn =
        :get
        |> conn("/api/v1/calls")
        |> put_req_header("authorization", "Bearer " <> @caller)
        |> CallController.index(%{})

      assert conn.status == 200
      [entry] = body(conn)["calls"]
      assert entry["e2ee"] == true
      assert entry["e2ee_accepted"] == true
      # History never carries key material, ended or not.
      refute Map.has_key?(entry, "e2ee_offer")
    end

    test "a plain call's history row says so" do
      row = call_row(%{status: "ended", e2ee: false, e2ee_accepted: nil, e2ee_offer: nil})
      conversation_stub(row)

      conn =
        :get
        |> conn("/api/v1/calls")
        |> put_req_header("authorization", "Bearer " <> @caller)
        |> CallController.index(%{})

      [entry] = body(conn)["calls"]
      assert entry["e2ee"] == false
    end
  end
end
