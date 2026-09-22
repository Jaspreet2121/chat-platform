defmodule ApiGatewayWeb.PushFcmTokenTest.AuthStub do
  @moduledoc false
  @behaviour SharedInfra.AuthClient

  @session %{
    user_id: "user-1",
    session_id: "s",
    device_id: "d",
    platform: "android",
    is_admin: false
  }

  @impl true
  def current_session(%{"authorization" => "Bearer good"}), do: {:ok, @session}
  # A session that carries no device — a placeholder, or one minted before device ids existed.
  def current_session(%{"authorization" => "Bearer deviceless"}),
    do: {:ok, %{@session | device_id: nil}}

  def current_session(_attrs), do: {:error, :session_invalid}

  @impl true
  def save_fcm_token(attrs) do
    send(self(), {:save_fcm_token, attrs})
    {:ok, %{saved: true}}
  end

  @impl true
  def delete_fcm_token(attrs) do
    send(self(), {:delete_fcm_token, attrs})
    {:ok, %{deleted: true}}
  end

  @impl true
  def persistence_enabled?, do: true

  # The behaviour is wide; only the four above are exercised here (same shape as the admin stubs).
  for fun <- [
        :lookup_user_by_phone,
        :request_otp,
        :verify_otp,
        :refresh,
        :revoke,
        :save_push_subscription,
        :delete_push_subscription
      ] do
    @impl true
    def unquote(fun)(_attrs), do: {:error, :not_implemented}
  end
end

defmodule ApiGatewayWeb.PushFcmTokenTest do
  @moduledoc """
  `POST/DELETE /api/v1/push/fcm-tokens` (Phase-2 Android registration): session-gated, one row per
  DEVICE, 204 with no body. The device id is the SESSION's, never the body's — the body's value used
  to be stored verbatim, and a client-claimed id is how one handset piled up three identities. The
  auth boundary is stubbed — this asserts the GATEWAY's contract, not the auth service's storage
  (that is `AuthService.FcmTokensTest`).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.PushFcmTokenTest.AuthStub

  @token "fcm-registration-token-aaaaaaaaaaaaaaaaaaaa"

  setup do
    prev = Application.get_env(:shared_infra, :auth_client_adapter)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:shared_infra, :auth_client_adapter, prev),
        else: Application.delete_env(:shared_infra, :auth_client_adapter)
    end)

    :ok
  end

  defp call(method, path, body, authorization \\ "Bearer good") do
    conn(method, path, body && Jason.encode!(body))
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> then(fn c ->
      if authorization, do: put_req_header(c, "authorization", authorization), else: c
    end)
    |> ApiGatewayWeb.Endpoint.call([])
  end

  test "POST registers the caller's token and answers 204 with no body" do
    conn = call(:post, "/api/v1/push/fcm-tokens", %{"token" => @token})

    assert conn.status == 204
    assert conn.resp_body == ""

    assert_received {:save_fcm_token, attrs}
    # BOTH identities come from the SESSION, never from the body — a client can register a token
    # against neither somebody else's account nor an invented device.
    assert attrs["user_id"] == "user-1"
    assert attrs["token"] == @token
    assert attrs["device_id"] == "d"

    # PLATFORM IS PASSED THROUGH, not decided here. It was hard-coded "android" until 129, which was
    # honest while Android was the only handset and silently wrong the moment it was not. A client
    # that says nothing sends nothing, and AuthService.FcmTokens applies the android default — one
    # place decides, and it is the place that owns the column.
    assert attrs["platform"] == nil
    assert attrs["kind"] == nil
    assert attrs["environment"] == nil
  end

  test "an iOS registration carries its channel and environment through to the store" do
    conn =
      call(:post, "/api/v1/push/fcm-tokens", %{
        "token" => @token,
        "platform" => "ios",
        "kind" => "voip",
        "environment" => "sandbox"
      })

    assert conn.status == 204
    assert_received {:save_fcm_token, attrs}

    # An iPhone registers TWO credentials for one device — an alert token and a VoIP token — and
    # they address different APNs topics. Losing `kind` here means calls never ring.
    assert attrs["platform"] == "ios"
    assert attrs["kind"] == "voip"
    assert attrs["environment"] == "sandbox"
    assert attrs["device_id"] == "d"
  end

  test "a body device_id is IGNORED — the session's device wins, a spoofed one never reaches the store" do
    conn =
      call(:post, "/api/v1/push/fcm-tokens", %{
        "token" => @token,
        "device_id" => "android-invented-by-the-client"
      })

    assert conn.status == 204
    assert_received {:save_fcm_token, attrs}

    assert attrs["device_id"] == "d",
           "the client's device_id (#{inspect(attrs["device_id"])}) was stored — a handset that " <>
             "mints a new id per install registers as a new device every time, and the old rows " <>
             "are never reclaimed"
  end

  test "a session with NO device id is a 422 — a deviceless row could never be updated or revoked" do
    conn = call(:post, "/api/v1/push/fcm-tokens", %{"token" => @token}, "Bearer deviceless")

    assert conn.status == 422
    assert %{"error" => %{"code" => "push.device_required"}} = Jason.decode!(conn.resp_body)
    refute_received {:save_fcm_token, _attrs}
  end

  test "DELETE unregisters the caller's own token (the logout call)" do
    conn = call(:delete, "/api/v1/push/fcm-tokens", %{"token" => @token})

    assert conn.status == 204
    assert_received {:delete_fcm_token, attrs}
    assert attrs == %{"user_id" => "user-1", "token" => @token}
  end

  test "a missing or blank token is push.invalid_token" do
    for body <- [%{}, %{"token" => ""}, %{"token" => 42}] do
      conn = call(:post, "/api/v1/push/fcm-tokens", body)
      assert conn.status == 400
      assert %{"error" => %{"code" => "push.invalid_token"}} = Jason.decode!(conn.resp_body)
    end

    conn = call(:delete, "/api/v1/push/fcm-tokens", %{})
    assert conn.status == 400
    assert %{"error" => %{"code" => "push.invalid_token"}} = Jason.decode!(conn.resp_body)
  end

  test "without a session the routes are 401, and nothing is registered" do
    assert call(:post, "/api/v1/push/fcm-tokens", %{"token" => @token}, nil).status == 401

    assert call(:post, "/api/v1/push/fcm-tokens", %{"token" => @token}, "Bearer bad").status ==
             401

    assert call(:delete, "/api/v1/push/fcm-tokens", %{"token" => @token}, nil).status == 401

    refute_received {:save_fcm_token, _attrs}
    refute_received {:delete_fcm_token, _attrs}
  end
end
