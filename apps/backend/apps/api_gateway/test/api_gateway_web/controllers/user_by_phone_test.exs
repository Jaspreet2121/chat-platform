defmodule ApiGatewayWeb.UserByPhoneTest.AuthStub do
  @moduledoc false
  # Session is always valid (user_1); the phone lookup resolves by the number passed:
  #   +19990000002 → another user (found), +19990000001 → user_1 (the caller → self), else → not found.
  @behaviour SharedInfra.AuthClient
  @session %{
    user_id: "user_1",
    session_id: "s",
    device_id: "d",
    platform: "ios",
    issued_at: "x",
    expires_at: "y"
  }
  @impl true
  def current_session(_attrs), do: {:ok, @session}
  @impl true
  def persistence_enabled?, do: true
  @impl true
  def request_otp(_attrs), do: {:ok, %{}}
  @impl true
  def verify_otp(_attrs), do: {:ok, %{}}
  @impl true
  def refresh(_attrs), do: {:ok, %{}}
  @impl true
  def revoke(_attrs), do: {:ok, %{}}

  @impl true
  def lookup_user_by_phone(%{"phone_number" => "+19990000002"}), do: {:ok, %{user_id: "user_2"}}
  def lookup_user_by_phone(%{"phone_number" => "+19990000001"}), do: {:ok, %{user_id: "user_1"}}
  def lookup_user_by_phone(_attrs), do: {:error, :not_found}

  for fun <- [
        :list_users,
        :get_user_detail,
        :suspend_user,
        :reactivate_user,
        :ban_user,
        :list_reports,
        :update_report,
        :write_audit,
        :list_audit
      ] do
    @impl true
    def unquote(fun)(_attrs), do: {:ok, %{}}
  end
end

defmodule ApiGatewayWeb.UserByPhoneTest.UserStub do
  @moduledoc false
  @behaviour SharedInfra.UserClient
  @impl true
  def get_public_profile(%{"user_id" => user_id}),
    do:
      {:ok,
       %{
         user_id: user_id,
         display_name: "Peer",
         avatar_media_id: nil,
         avatar_object_key: nil,
         bio: nil
       }}

  @impl true
  def get_current_profile(_attrs), do: {:ok, %{}}
  @impl true
  def update_current_profile(_attrs), do: {:ok, %{}}
end

defmodule ApiGatewayWeb.UserByPhoneTest do
  @moduledoc """
  Plain (Docker-free, no network): GET /api/v1/users/by-phone is session-gated and maps the phone
  lookup outcomes — found → 200 (public profile shape), unknown → 404, your own number → 409, and a
  missing token → 401. Auth + User clients are stubbed; no DB/HTTP involved.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.UserByPhoneTest.{AuthStub, UserStub}

  @opts ApiGatewayWeb.Router.init([])

  setup do
    prev_auth = Application.get_env(:shared_infra, :auth_client_adapter)
    prev_user = Application.get_env(:shared_infra, :user_client_adapter)

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)

    on_exit(fn ->
      restore(:shared_infra, :auth_client_adapter, prev_auth)
      restore(:shared_infra, :user_client_adapter, prev_user)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)

  # %2B is the URL-encoding of "+" — a raw "+" in a query string decodes to a space. Calling the
  # Router directly bypasses the Endpoint, so fetch query params explicitly (the controller matches
  # on the "phone" query param).
  defp lookup(phone, headers) do
    headers
    |> Enum.reduce(conn(:get, "/api/v1/users/by-phone?phone=#{phone}"), fn {k, v}, c ->
      put_req_header(c, k, v)
    end)
    |> fetch_query_params()
    |> ApiGatewayWeb.Router.call(@opts)
  end

  test "missing token → 401" do
    conn = lookup("%2B19990000002", [{"accept", "application/json"}])
    assert conn.status == 401
    assert %{"error" => %{"code" => "auth.session_invalid"}} = Jason.decode!(conn.resp_body)
  end

  test "registered number → 200 with the public profile shape" do
    conn =
      lookup("%2B19990000002", [{"accept", "application/json"}, {"authorization", "Bearer x"}])

    assert conn.status == 200
    assert %{"user_id" => "user_2", "display_name" => "Peer"} = Jason.decode!(conn.resp_body)
  end

  test "unregistered number → 404 phone_not_found" do
    conn =
      lookup("%2B10000000000", [{"accept", "application/json"}, {"authorization", "Bearer x"}])

    assert conn.status == 404
    assert %{"error" => %{"code" => "user.phone_not_found"}} = Jason.decode!(conn.resp_body)
  end

  test "your own number → 409 self_lookup" do
    conn =
      lookup("%2B19990000001", [{"accept", "application/json"}, {"authorization", "Bearer x"}])

    assert conn.status == 409
    assert %{"error" => %{"code" => "user.self_lookup"}} = Jason.decode!(conn.resp_body)
  end
end
