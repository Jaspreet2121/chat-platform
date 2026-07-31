defmodule ApiGatewayWeb.ReportControllerTest do
  @moduledoc """
  POST /api/v1/reports — first-party user reporting. Session-authed; reporter = session user. Stubs AuthClient
  (session + create_report) and uses the real in-memory RateLimiter. Proves the contract: 201 {report_id},
  reason validated against the fixed set, details capped, per-reporter rate limit → 429, and the session gate.
  The row landing in user_reports + the admin console seeing it is proven in the auth_service postgres suite.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.ReportController

  # @me / @app live inside AuthStub (the session identity); the test body only references the reported user.
  @reported "22222222-2222-4222-8222-222222222222"

  defmodule AuthStub do
    @me "11111111-1111-4111-8111-111111111111"
    @app "33333333-3333-4333-8333-333333333333"
    def current_session(%{"authorization" => "Bearer me"}),
      do: {:ok, %{user_id: @me, app_id: @app}}

    def current_session(_), do: {:error, :session_invalid}

    def create_report(%{"reported_user_id" => "ghost"}), do: {:error, :report_invalid}
    def create_report(_attrs), do: {:ok, %{report_id: "report-1"}}
  end

  setup do
    prev_auth = Application.get_env(:shared_infra, :auth_client_adapter)
    prev_rl = Application.get_env(:shared_infra, :rate_limiter_adapter)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)

    Application.put_env(
      :shared_infra,
      :rate_limiter_adapter,
      SharedInfra.RateLimiter.InMemoryAdapter
    )

    SharedInfra.RateLimiter.InMemoryAdapter.reset()

    on_exit(fn ->
      restore(:auth_client_adapter, prev_auth)
      restore(:rate_limiter_adapter, prev_rl)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  defp post(params, token \\ "me") do
    :post
    |> conn("/api/v1/reports", %{})
    |> put_req_header("authorization", "Bearer #{token}")
    |> ReportController.create(params)
  end

  test "a valid report → 201 {report_id}" do
    conn = post(%{"reported_user_id" => @reported, "reason" => "spam"})
    assert conn.status == 201
    assert Jason.decode!(conn.resp_body)["report_id"] == "report-1"
  end

  test "a report with details + conversation context → 201" do
    conn =
      post(%{
        "reported_user_id" => @reported,
        "reason" => "harassment",
        "details" => "kept messaging me",
        "conversation_id" => "44444444-4444-4444-8444-444444444444"
      })

    assert conn.status == 201
  end

  test "an invalid reason → 400" do
    conn = post(%{"reported_user_id" => @reported, "reason" => "because"})
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "reports.invalid_reason"
  end

  test "a missing reason → 400" do
    conn = post(%{"reported_user_id" => @reported})
    assert conn.status == 400
  end

  test "details over the cap → 400" do
    conn =
      post(%{
        "reported_user_id" => @reported,
        "reason" => "other",
        "details" => String.duplicate("a", 2001)
      })

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "reports.details_too_long"
  end

  test "no reported_user_id → 400" do
    conn = post(%{"reason" => "spam"})
    assert conn.status == 400
  end

  test "per-reporter RATE LIMIT: the 6th report in the window → 429" do
    for _ <- 1..5 do
      assert post(%{"reported_user_id" => @reported, "reason" => "spam"}).status == 201
    end

    conn = post(%{"reported_user_id" => @reported, "reason" => "spam"})
    assert conn.status == 429
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "reports.rate_limited"
  end

  test "no session → 401" do
    conn = post(%{"reported_user_id" => @reported, "reason" => "spam"}, "nobody")
    assert conn.status == 401
  end
end
