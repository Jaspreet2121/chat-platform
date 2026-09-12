defmodule UserService.HealthGitShaTest do
  @moduledoc """
  `/internal/health` reports which build this service is running.

  The gateway's public /health answers the question for the gateway only; in a split deployment the
  services are separate images that can be a commit apart, and "the fleet is on the new build" is
  answered per service or not at all. Driven through the REAL router, so a handler that stops
  emitting the key fails here rather than at 2am on the box.
  """
  use ExUnit.Case, async: false

  @token "health-test-internal-token"

  setup do
    previous = System.get_env("GIT_SHA")
    previous_token = Application.get_env(:shared_infra, :internal_api_token)
    Application.put_env(:shared_infra, :internal_api_token, @token)

    on_exit(fn ->
      if previous, do: System.put_env("GIT_SHA", previous), else: System.delete_env("GIT_SHA")

      if previous_token,
        do: Application.put_env(:shared_infra, :internal_api_token, previous_token),
        else: Application.delete_env(:shared_infra, :internal_api_token)
    end)

    :ok
  end

  # The internal API is token-gated (SharedInfra.InternalApi.TokenPlug, fail-closed), so the probe
  # carries the header the gateway would — this exercises the route as it is actually reached.
  defp health do
    conn =
      UserService.HTTP.Router.call(
        Plug.Test.conn(:get, "/internal/health")
        |> Plug.Conn.put_req_header("x-internal-token", @token),
        UserService.HTTP.Router.init([])
      )

    assert conn.status == 200

    # The internal envelope: every in-process result rides inside {"ok": ...} (SharedInfra.InternalApi).
    %{"ok" => body} = Jason.decode!(conn.resp_body)
    body
  end

  test "carries git_sha beside service/status" do
    System.put_env("GIT_SHA", "2cc6370")

    body = health()

    assert body["git_sha"] == "2cc6370",
           "user-service's health does not report its build — a mixed fleet mid-deploy is " <>
             "invisible from outside the box"

    assert body["service"] == "user"
    assert body["status"] == "ok"
  end

  test "with no SHA in the image it still answers a string" do
    System.delete_env("GIT_SHA")
    assert health()["git_sha"] == "unknown"
  end
end
