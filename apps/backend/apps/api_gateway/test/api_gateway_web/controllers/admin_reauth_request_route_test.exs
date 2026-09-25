defmodule ApiGatewayWeb.AdminReauthRequestRouteTest do
  @moduledoc """
  A root admin WITHOUT a step-up proof gets 2xx from POST /api/v1/admin/reauth/request.

  Obvious, and that is the point: the request endpoint is how a proof is obtained, so it can never
  itself require one. A RequireReauth plug on this controller, or on the pipeline that wraps it, is
  a chicken-and-egg lock that makes ban and delete permanently unusable — and it would look, from
  the outside, exactly like the outage this suite was written after (403 at the gateway, nothing
  reaching auth). This is the test that tells the two apart.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  @opts ApiGatewayWeb.Router.init([])

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer root"}),
      do:
        {:ok,
         %{
           user_id: "root-1",
           session_id: "s",
           device_id: "d",
           platform: "web",
           is_admin: true,
           role: "root",
           permissions: SharedInfra.IAM.permissions_for("root")
         }}

    def current_session(_), do: {:error, :session_invalid}

    # What auth answers once the changeset accepts the purpose: a request id, no destination.
    def admin_reauth_request(%{"user_id" => "root-1"}),
      do:
        {:ok,
         %{
           otp_request_id: "11111111-1111-1111-1111-111111111111",
           delivery_method: "sms",
           expires_in_seconds: 300,
           retry_after_seconds: 30
         }}

    # A proof check must never be consulted on this route. If it is, fail loudly rather than pass.
    def admin_reauth_check(_), do: raise("RequireReauth ran on the reauth request route")
  end

  setup do
    previous = Application.get_env(:shared_infra, :auth_client_adapter)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shared_infra, :auth_client_adapter, previous),
        else: Application.delete_env(:shared_infra, :auth_client_adapter)
    end)

    :ok
  end

  test "root with a plain session and NO x-admin-reauth header gets 200 and a request id" do
    conn =
      conn(:post, "/api/v1/admin/reauth/request", %{})
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer root")
      |> ApiGatewayWeb.Router.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["otp_request_id"] == "11111111-1111-1111-1111-111111111111"

    # The number the code went to is not in the response — the destination is the server's secret.
    refute Map.has_key?(body, "phone_number")
    refute Map.has_key?(body, "destination")
  end

  test "no session at all is 401, not 403 — the two must stay distinguishable" do
    conn =
      conn(:post, "/api/v1/admin/reauth/request", %{})
      |> put_req_header("accept", "application/json")
      |> ApiGatewayWeb.Router.call(@opts)

    assert conn.status == 401
  end
end
