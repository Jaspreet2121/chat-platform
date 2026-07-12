defmodule ApiGatewayWeb.UsageDeliveriesTest do
  @moduledoc """
  Owner-console usage + webhook delivery log. Docker-free: stubs the AuthClient so we exercise the OWNERSHIP
  GATE (ApiGatewayWeb.AppOwnerAuth), the app_id threading, the response shape, and the no-leak guarantees.
  The SQL itself (counts via the parent conversation; cross-app row isolation) is covered by the
  @postgres_integration suite in auth_service.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  @opts ApiGatewayWeb.Router.init([])
  @owned "11111111-1111-4111-8111-111111111111"
  @not_owned "22222222-2222-4222-8222-222222222222"

  defmodule AuthStub do
    @moduledoc false
    # The owner (user "owner-1") owns @owned ONLY. owns_app is the app_owners gate.
    def current_session(_attrs),
      do: {:ok, %{user_id: "owner-1", app_id: "00000000-0000-4000-8000-000000000000"}}

    def owns_app(%{"app_id" => "11111111-1111-4111-8111-111111111111"}), do: {:ok, %{}}
    def owns_app(_attrs), do: {:error, :forbidden}

    # Echo the app_id back so the test can prove the OWNED app was the one queried.
    def app_usage(%{"app_id" => app_id}),
      do: {:ok, %{app_id: app_id, users: 3, conversations: 2, messages: 7, storage_bytes: 1024}}

    def list_webhook_deliveries(%{"app_id" => app_id} = attrs) do
      {:ok,
       %{
         items: [
           %{
             "id" => "d1",
             "event_id" => "e1",
             "event_type" => "message.created",
             "status" => "failed",
             "attempts" => 3,
             "last_error" => "500 from endpoint",
             "endpoint_id" => "ep1",
             "endpoint_url" => "https://owner.example/hook",
             "created_at" => "2026-07-11T00:00:00Z",
             "delivered_at" => nil,
             "next_attempt_at" => "2026-07-11T00:05:00Z",
             # Proves the app_id + filters actually reached the query layer.
             "_app_id" => app_id,
             "_status_filter" => Map.get(attrs, "status"),
             "_limit" => Map.get(attrs, "limit"),
             "_cursor_ts" => Map.get(attrs, "cursor_ts")
           }
         ],
         next_cursor: %{"created_at" => "2026-07-11T00:00:00Z", "id" => "d1"},
         count: 1
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
    # Calling the Router directly bypasses the Endpoint, which is what normally fetches the query string.
    |> fetch_query_params()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer owner-session")
    |> ApiGatewayWeb.Router.call(@opts)
  end

  # --- usage ---------------------------------------------------------------------------------------

  test "GET /usage for an OWNED app → 200 with the real counts, scoped to that app" do
    conn = get_json("/api/v1/usage?app_id=#{@owned}")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert body["app_id"] == @owned
    assert body["users"] == 3
    assert body["conversations"] == 2
    assert body["messages"] == 7
    assert body["storage_bytes"] == 1024
  end

  test "GET /usage for an app the caller does NOT own → 403 (never another app's numbers)" do
    conn = get_json("/api/v1/usage?app_id=#{@not_owned}")
    assert conn.status == 403
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "usage.forbidden_app"
    # No usage numbers leak in the error body.
    refute Map.has_key?(body, "users")
  end

  # --- deliveries ----------------------------------------------------------------------------------

  test "GET /webhooks/deliveries for an OWNED app → rows for THAT app, with an opaque next_cursor" do
    conn = get_json("/api/v1/webhooks/deliveries?app_id=#{@owned}")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    [row] = body["deliveries"]
    # The query ran against the OWNED app id.
    assert row["_app_id"] == @owned
    assert row["event_type"] == "message.created"
    assert row["status"] == "failed"
    assert row["attempts"] == 3
    assert row["last_error"] == "500 from endpoint"
    assert row["endpoint_id"] == "ep1"
    # The cursor is opaque (base64), not a raw timestamp.
    assert is_binary(body["next_cursor"])
    refute body["next_cursor"] =~ "2026-"
  end

  test "deliveries NEVER exposes the signing_secret or the outbox payload (message content)" do
    conn = get_json("/api/v1/webhooks/deliveries?app_id=#{@owned}")
    body = conn.resp_body

    refute body =~ "signing_secret"
    # `payload` is the event body (a message.created payload carries message CONTENT) — never selected.
    refute body =~ "\"payload\""
  end

  test "deliveries for an app the caller does NOT own → 403" do
    conn = get_json("/api/v1/webhooks/deliveries?app_id=#{@not_owned}")
    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "webhook.forbidden_app"
  end

  test "deliveries threads status + limit filters, and round-trips the opaque cursor" do
    cursor = Base.url_encode64("2026-07-11T00:00:00Z|d0", padding: false)

    conn = get_json("/api/v1/webhooks/deliveries?app_id=#{@owned}&status=failed&limit=5&cursor=#{cursor}")
    assert conn.status == 200
    [row] = Jason.decode!(conn.resp_body)["deliveries"]

    assert row["_status_filter"] == "failed"
    assert row["_limit"] == "5"
    # The opaque cursor was decoded back into its (created_at, id) keyset parts.
    assert row["_cursor_ts"] == "2026-07-11T00:00:00Z"
  end
end
