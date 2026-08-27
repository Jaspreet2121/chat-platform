defmodule ApiGatewayWeb.StatusSettingsTest do
  @moduledoc """
  The status DURATION endpoints (112) at the gateway.

  Two things are pinned here that the domain tests cannot see: identity comes from the SESSION (never
  the body, so a client cannot set someone else's duration), and the `status.invalid_duration` refusal
  carries the ALLOWED LIST — which is the whole point of a server-owned enum. A client renders its
  picker from that list, so if it stopped being served, every client would have to hardcode 6/12/24/48
  and would silently disagree with the server the day the enum widens.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.StatusController

  @me "11111111-1111-4111-8111-111111111111"

  defmodule AuthStub do
    def current_session(%{"authorization" => "Bearer " <> uid}) when uid != "",
      do: {:ok, %{user_id: uid, app_id: "app1"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule MsgStub do
    # Echoes the user_id it received so the tests can prove the SESSION supplied it.
    def get_status_settings(%{"user_id" => uid}),
      do: {:ok, %{duration_hours: 24, allowed_duration_hours: [6, 12, 24, 48], echo_user: uid}}

    def set_status_settings(%{"user_id" => uid, "duration_hours" => hours}) do
      if hours in [6, 12, 24, 48] or hours in ["6", "12", "24", "48"] do
        {:ok,
         %{
           duration_hours: if(is_binary(hours), do: String.to_integer(hours), else: hours),
           allowed_duration_hours: [6, 12, 24, 48],
           echo_user: uid
         }}
      else
        {:error, :status_invalid_duration}
      end
    end
  end

  setup do
    prev = %{
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      msg: Application.get_env(:shared_infra, :message_client_adapter)
    }

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)

    on_exit(fn ->
      for {key, value} <- [auth_client_adapter: prev.auth, message_client_adapter: prev.msg] do
        if value,
          do: Application.put_env(:shared_infra, key, value),
          else: Application.delete_env(:shared_infra, key)
      end
    end)

    :ok
  end

  defp authed(method, token \\ @me) do
    method |> conn("/x", %{}) |> put_req_header("authorization", "Bearer #{token}")
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "GET /settings returns the caller's duration AND the allowed list" do
    conn = StatusController.get_settings(authed(:get), %{})

    assert conn.status == 200
    b = body(conn)
    assert b["duration_hours"] == 24
    # Served so clients render the picker from the server rather than hardcoding it.
    assert b["allowed_duration_hours"] == [6, 12, 24, 48]
    # Identity came from the session, not the request.
    assert b["echo_user"] == @me
  end

  test "PUT /settings sets it, and takes the user from the SESSION not the body" do
    conn =
      StatusController.set_settings(authed(:put), %{
        "duration_hours" => 6,
        # A client cannot set someone else's duration by naming them.
        "user_id" => "99999999-9999-4999-8999-999999999999"
      })

    assert conn.status == 200
    assert body(conn)["duration_hours"] == 6
    assert body(conn)["echo_user"] == @me
  end

  test "an invalid duration is 400 status.invalid_duration WITH the allowed list in the body" do
    conn = StatusController.set_settings(authed(:put), %{"duration_hours" => 5})

    assert conn.status == 400
    error = body(conn)["error"]
    assert error["code"] == "status.invalid_duration"

    # THE POINT: the refusal tells the client what IS allowed, so it can correct itself and render its
    # picker without shipping a new build.
    assert error["allowed_duration_hours"] == [6, 12, 24, 48]
  end

  test "a missing duration is refused the same way" do
    conn = StatusController.set_settings(authed(:put), %{})

    assert conn.status == 400
    assert body(conn)["error"]["code"] == "status.invalid_duration"
  end

  test "no session → 401 on both endpoints" do
    assert StatusController.get_settings(conn(:get, "/x", %{}), %{}).status == 401

    assert StatusController.set_settings(conn(:put, "/x", %{}), %{"duration_hours" => 6}).status ==
             401
  end

  test "the served allowed list is the SHARED enum, not a gateway-local copy" do
    # The gateway release does not contain MessageService, so this list must come from shared_infra —
    # reaching across releases would compile here and crash in production.
    conn = StatusController.set_settings(authed(:put), %{"duration_hours" => 99})

    assert body(conn)["error"]["allowed_duration_hours"] == SharedInfra.StatusDuration.allowed()
  end
end
