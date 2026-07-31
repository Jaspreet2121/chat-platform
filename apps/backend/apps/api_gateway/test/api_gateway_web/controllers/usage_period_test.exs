defmodule ApiGatewayWeb.UsagePeriodTest do
  @moduledoc """
  The `?period=` surface on the owner usage endpoint + the admin per-app meter. Docker-free stubs — the SQL
  itself is proven in AuthService.AppUsagePeriodTest (real Postgres). What THIS pins: the routing (absent
  param → the UNCHANGED lifetime call; present → the period call), the 422 mapping, the ownership gate
  still applying, and the admin default-to-current-month.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  @opts ApiGatewayWeb.Router.init([])
  @owned "11111111-1111-4111-8111-111111111111"
  @not_owned "22222222-2222-4222-8222-222222222222"

  defmodule AuthStub do
    @moduledoc false
    def current_session(_attrs),
      do: {:ok, %{user_id: "owner-1", app_id: "00000000-0000-4000-8000-000000000000"}}

    def owns_app(%{"app_id" => "11111111-1111-4111-8111-111111111111"}), do: {:ok, %{}}
    def owns_app(_attrs), do: {:error, :forbidden}

    def app_usage(%{"app_id" => app_id}),
      do: {:ok, %{app_id: app_id, users: 3, conversations: 2, messages: 7, storage_bytes: 1024}}

    def app_usage_period(%{"app_id" => app_id, "period" => "2026-13"}),
      do:
        {:error, :invalid_period}
        |> tap(fn _ -> send(self(), {:period_called, app_id, "2026-13"}) end)

    def app_usage_period(%{"app_id" => app_id, "period" => period}) do
      {:ok,
       %{
         app_id: app_id,
         period: period,
         period_start: "#{period}-01T00:00:00Z",
         period_end: "next",
         messages_sent: 42,
         active_users_by_messages: 5,
         call_seconds: 300,
         storage_bytes_snapshot: 2048
       }}
    end
  end

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

  defp get_json(path) do
    :get
    |> conn(path)
    |> fetch_query_params()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer owner-session")
    |> ApiGatewayWeb.Router.call(@opts)
  end

  test "?period routes to the PERIOD meter and returns its block" do
    conn = get_json("/api/v1/usage?app_id=#{@owned}&period=2026-06")

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["period"] == "2026-06"
    assert body["messages_sent"] == 42
    assert body["active_users_by_messages"] == 5
    assert body["call_seconds"] == 300
    assert body["storage_bytes_snapshot"] == 2048
    refute Map.has_key?(body, "users")
  end

  test "ABSENT period → the lifetime response, byte-compatible with before (additive change)" do
    conn = get_json("/api/v1/usage?app_id=#{@owned}")

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["messages"] == 7
    assert body["users"] == 3
    refute Map.has_key?(body, "messages_sent")
  end

  test "a malformed period → 422 usage.invalid_period" do
    conn = get_json("/api/v1/usage?app_id=#{@owned}&period=2026-13")
    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "usage.invalid_period"
  end

  test "the ownership gate still applies with a period (cross-tenant → 403)" do
    conn = get_json("/api/v1/usage?app_id=#{@not_owned}&period=2026-06")
    assert conn.status == 403
  end

  describe "admin per-app meter (action-level; RequirePermission gating covered by the admin suite)" do
    test "explicit period passes through" do
      conn =
        :get
        |> conn("/x")
        |> ApiGatewayWeb.AdminAppsController.usage(%{"id" => @owned, "period" => "2026-05"})

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["period"] == "2026-05"
    end

    test "absent period defaults to the CURRENT UTC month" do
      now = DateTime.utc_now()
      expected = "#{now.year}-#{String.pad_leading(Integer.to_string(now.month), 2, "0")}"

      conn = :get |> conn("/x") |> ApiGatewayWeb.AdminAppsController.usage(%{"id" => @owned})

      assert Jason.decode!(conn.resp_body)["period"] == expected
    end

    test "invalid period → 422" do
      conn =
        :get
        |> conn("/x")
        |> ApiGatewayWeb.AdminAppsController.usage(%{"id" => @owned, "period" => "2026-13"})

      assert conn.status == 422
    end
  end
end
