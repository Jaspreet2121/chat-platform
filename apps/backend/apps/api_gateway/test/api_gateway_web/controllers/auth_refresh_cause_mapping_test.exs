defmodule ApiGatewayWeb.RefreshCauseStub do
  @moduledoc false
  # Stand-in Auth client returning whatever refresh cause the test asks for. No network, no DB —
  # this pins the ATOM → HTTP CODE mapping, which is the whole contract this slice adds.
  @behaviour SharedInfra.AuthClient

  def put_reason(reason), do: :persistent_term.put({__MODULE__, :reason}, reason)

  @impl true
  def refresh(_attrs), do: {:error, :persistent_term.get({__MODULE__, :reason})}

  @impl true
  def revoke(_attrs), do: {:error, :persistent_term.get({__MODULE__, :reason})}

  @impl true
  def current_session(_attrs), do: {:error, :session_invalid}
  @impl true
  def persistence_enabled?, do: true
  @impl true
  def request_otp(_attrs), do: {:error, :otp_invalid}
  @impl true
  def verify_otp(_attrs), do: {:error, :otp_invalid}

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
    def unquote(fun)(_attrs), do: {:error, :auth_unavailable}
  end
end

defmodule ApiGatewayWeb.AuthRefreshCauseMappingTest do
  @moduledoc """
  Docker-free: the four refresh outcomes, each mapped to its own error code at HTTP 401.

  WHY THIS EXISTS. Every refusal used to be `auth.refresh_invalid`, so a client could not tell an
  ordinary expiry from a possible compromise — and Android's only safe reading of the ambiguity was
  to wipe all local data, E2EE keys included, on a routine 7-day expiry. The status is deliberately
  UNCHANGED (401 throughout): old clients key off the status alone and are unaffected; new clients
  read the code and can keep local data when it merely expired.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @opts ApiGatewayWeb.Router.init([])

  setup do
    previous = Application.get_env(:shared_infra, :auth_client_adapter)
    Application.put_env(:shared_infra, :auth_client_adapter, ApiGatewayWeb.RefreshCauseStub)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shared_infra, :auth_client_adapter, previous),
        else: Application.delete_env(:shared_infra, :auth_client_adapter)
    end)

    :ok
  end

  defp refresh_with(reason) do
    ApiGatewayWeb.RefreshCauseStub.put_reason(reason)

    :post
    |> conn("/api/v1/auth/refresh", %{"refresh_token" => "t", "device_id" => "d"})
    |> put_req_header("accept", "application/json")
    |> ApiGatewayWeb.Router.call(@opts)
  end

  defp code(conn), do: Jason.decode!(conn.resp_body)["error"]["code"]

  test "each cause maps to its OWN code, all at 401" do
    for {reason, expected} <- [
          {:refresh_expired, "auth.refresh_expired"},
          {:refresh_reused, "auth.refresh_reused"},
          {:session_revoked, "auth.session_revoked"},
          {:refresh_invalid, "auth.refresh_invalid"}
        ] do
      conn = refresh_with(reason)

      assert conn.status == 401, "#{reason} must stay 401 — old clients key off the status alone"
      assert code(conn) == expected
    end
  end

  test "the four codes are DISTINCT — a collapse defeats the entire point" do
    codes =
      for reason <- [:refresh_expired, :refresh_reused, :session_revoked, :refresh_invalid],
          do: code(refresh_with(reason))

    assert length(Enum.uniq(codes)) == 4, "got #{inspect(codes)}"
  end

  test "an UNRECOGNISED cause falls back to the conservative catch-all, never a 500" do
    # Including the case that matters most in a split release: auth ships an atom this gateway has
    # never heard of. InternalApi.decode_result/2 hands over the raw STRING, which matches no clause.
    conn = refresh_with(:something_new_from_a_newer_auth_release)

    assert conn.status in [400, 401]
    assert is_binary(code(conn))
  end

  test "every error body keeps the existing envelope" do
    body = Jason.decode!(refresh_with(:refresh_expired).resp_body)

    assert %{"error" => %{"code" => _, "message" => message}} = body
    assert is_binary(message) and message != ""
  end
end
