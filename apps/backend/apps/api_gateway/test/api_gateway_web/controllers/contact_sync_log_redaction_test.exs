defmodule ApiGatewayWeb.ContactSyncLogRedactionTest do
  @moduledoc """
  A contacts-sync request logged at DEBUG must show `[FILTERED]`, never the numbers.

  Phoenix's request logger prints `Parameters: %{...}` at :debug for every routed request. For
  POST /api/v1/contacts/sync that map is up to 2,000 numbers from somebody's address book, and for
  GET /api/v1/users/by-phone it is one real phone number in the query string. Prod logs at :info,
  so these lines are not written today — but the privacy policy says "not written to our logs",
  and a level bump to chase a bug must not quietly make that false. So the keys are in
  `:phoenix, :filter_parameters`, and this test raises the level to :debug, sends the requests
  THROUGH THE ROUTER (the filter lives in the router-dispatch telemetry, which a direct controller
  call never fires), and reads the log.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  @opts ApiGatewayWeb.Router.init([])
  @number "+15550000001"

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer me"}),
      do: {:ok, %{user_id: "u-me", app_id: "app-1"}}

    def current_session(_), do: {:error, :session_invalid}
    def lookup_users_by_phones(_), do: {:ok, []}
    def lookup_user_by_phone(_), do: {:error, :not_found}
  end

  defmodule RateOkStub do
    @moduledoc false
    def check_rate(_), do: :ok
  end

  setup do
    keys = [:auth_client_adapter, :rate_limiter_adapter]
    prev = Map.new(keys, &{&1, Application.get_env(:shared_infra, &1)})
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :rate_limiter_adapter, RateOkStub)

    # The whole point: the level at which the Parameters line IS emitted.
    previous_level = Logger.level()
    Logger.configure(level: :debug)

    on_exit(fn ->
      Logger.configure(level: previous_level)

      for {key, value} <- prev do
        if value == nil,
          do: Application.delete_env(:shared_infra, key),
          else: Application.put_env(:shared_infra, key, value)
      end
    end)

    :ok
  end

  defp request(conn),
    do: ApiGatewayWeb.Router.call(put_req_header(conn, "authorization", "Bearer me"), @opts)

  test "POST /contacts/sync logged at debug shows [FILTERED] for phone_numbers, never a number" do
    log =
      capture_log(fn ->
        conn = request(conn(:post, "/api/v1/contacts/sync", %{"phone_numbers" => [@number]}))
        assert conn.status == 200
      end)

    # The line was actually emitted (otherwise the refute below proves nothing).
    assert log =~ "Parameters:"
    assert log =~ ~s("phone_numbers" => "[FILTERED]")
    refute log =~ @number
  end

  test "GET /users/by-phone logged at debug shows [FILTERED] for phone, never the number" do
    log =
      capture_log(fn ->
        # Params are passed as a map because the router is called directly: Plug.Parsers, which
        # would populate them from the query string, is an ENDPOINT plug and does not run here.
        request(conn(:get, "/api/v1/users/by-phone", %{"phone" => @number}))
      end)

    assert log =~ "Parameters:"
    assert log =~ ~s("phone" => "[FILTERED]")
    refute log =~ @number
  end
end
