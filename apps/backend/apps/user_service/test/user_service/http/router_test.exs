defmodule UserService.HTTP.RouterTest do
  @moduledoc """
  Drives the user internal HTTP API via Plug.Test (synthetic conn — NO listener/port), plain/
  Docker-free on the persistence-off (placeholder) paths. Asserts the internal result-envelope +
  that `decode_result` reconstructs the exact in-process (atom-keyed) profile shape + the
  internal-auth plug rejection. Error-atom round-trip is covered in `SharedInfra.InternalApiTest`.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @opts UserService.HTTP.Router.init([])
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

  defp call(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-internal-token", @token)
    |> UserService.HTTP.Router.call(@opts)
  end

  test "POST /internal/profiles/public returns {\"ok\": profile}; decode matches in-process (atom keys)" do
    attrs = %{"user_id" => "user_1"}
    conn = call("/internal/profiles/public", attrs)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert %{"ok" => _} = body

    assert SharedInfra.InternalApi.decode_result(body) ==
             UserService.Profiles.get_public_profile(attrs)
  end

  test "POST /internal/profiles/current returns {\"ok\": ...} (placeholder path)" do
    conn = call("/internal/profiles/current", %{"user_id" => "user_1"})
    assert conn.status == 200
    assert %{"ok" => _} = Jason.decode!(conn.resp_body)
  end

  test "POST /internal/profiles/update returns {\"ok\": profile}; decode matches in-process" do
    attrs = %{"user_id" => "user_1", "display_name" => "Ada"}
    conn = call("/internal/profiles/update", attrs)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert SharedInfra.InternalApi.decode_result(body) ==
             UserService.Profiles.update_current_profile(attrs)
  end

  test "rejects (401) a request missing the internal token" do
    conn =
      conn(:post, "/internal/profiles/public", Jason.encode!(%{}))
      |> put_req_header("content-type", "application/json")
      |> UserService.HTTP.Router.call(@opts)

    assert conn.status == 401
    assert conn.halted
  end
end
