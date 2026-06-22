defmodule AuthService.HTTP.RouterTest do
  @moduledoc """
  Drives the internal HTTP API via Plug.Test (synthetic conn — NO listener/port/network), so it
  is plain/Docker-free for the persistence-off (placeholder) paths. Asserts the internal
  result-envelope shape + that the internal-auth plug rejects a missing token. The future HTTP
  client adapter decodes these bodies via `SharedInfra.InternalApi.decode_result/1`.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @opts AuthService.HTTP.Router.init([])
  @token "test-internal-token"

  setup do
    previous = Application.get_env(:shared_infra, :internal_api_token)
    Application.put_env(:shared_infra, :internal_api_token, @token)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shared_infra, :internal_api_token, previous),
        else: Application.delete_env(:shared_infra, :internal_api_token)
    end)

    :ok
  end

  defp call(method, path, body \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn
    |> put_req_header("x-internal-token", @token)
    |> AuthService.HTTP.Router.call(@opts)
  end

  test "GET /internal/sessions/persistence_enabled returns the bare boolean envelope" do
    conn = call(:get, "/internal/sessions/persistence_enabled")
    assert conn.status == 200
    # persistence off by default → false, carried as {"result": false}
    assert Jason.decode!(conn.resp_body) == %{"result" => false}
  end

  test "POST /internal/sessions/current returns {\"ok\": session} (placeholder path)" do
    conn = call(:post, "/internal/sessions/current", %{"authorization" => "Bearer whatever"})
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert %{"ok" => session} = body
    assert session["user_id"] == "user_placeholder"
    # decode_result reconstructs the exact in-process shape (atom keys)
    assert SharedInfra.InternalApi.decode_result(body) ==
             AuthService.Sessions.current_session(%{"authorization" => "Bearer whatever"})
  end

  test "POST /internal/otp/request returns an {\"ok\": ...} envelope (placeholder path)" do
    conn =
      call(:post, "/internal/otp/request", %{
        "phone_number" => "+15551230000",
        "purpose" => "login"
      })

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert %{"ok" => _} = body
    # decode_result reconstructs the exact in-process shape
    assert SharedInfra.InternalApi.decode_result(body) ==
             AuthService.OTP.request_otp(%{
               "phone_number" => "+15551230000",
               "purpose" => "login"
             })
  end

  # NOTE: error-ATOM envelope serialization/round-trip is proven in SharedInfra.InternalApiTest
  # (no placeholder/persistence-off path returns an error atom, so it can't be exercised plainly here).

  test "rejects (401) a request missing the internal token" do
    conn =
      conn(:get, "/internal/sessions/persistence_enabled")
      |> AuthService.HTTP.Router.call(@opts)

    assert conn.status == 401
    assert conn.halted
  end
end
