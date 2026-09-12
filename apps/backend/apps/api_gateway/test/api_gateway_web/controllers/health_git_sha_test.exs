defmodule ApiGatewayWeb.HealthGitShaTest do
  @moduledoc """
  `curl https://api.growblic.com/health` has to answer "is the new build running?".

  Pinned here: the PUBLIC liveness payload's whole key-set (a health response is a wire contract —
  monitors parse it), that git_sha carries the running build's value, and that a build with no SHA
  passed in still answers with a string rather than a null or a missing key.
  """
  use ExUnit.Case, async: false

  import Plug.Test

  alias ApiGatewayWeb.HealthController

  setup do
    previous = System.get_env("GIT_SHA")

    on_exit(fn ->
      if previous, do: System.put_env("GIT_SHA", previous), else: System.delete_env("GIT_SHA")
    end)

    :ok
  end

  defp health do
    conn = HealthController.show(conn(:get, "/health"), %{})
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  test "/health carries git_sha alongside the existing keys" do
    System.put_env("GIT_SHA", "2cc6370")

    body = health()

    assert body["git_sha"] == "2cc6370",
           "the public health payload does not report the build — answering 'is the new image " <>
             "running?' goes back to an rpc into the container"

    # THE WHOLE KEY-SET: status and service are what every existing monitor reads; the slice adds a
    # key and changes nothing else.
    assert body |> Map.keys() |> Enum.sort() == ["git_sha", "service", "status"]
    assert body["status"] == "ok"
    assert body["service"] == "api_gateway"
  end

  test "an image built with no SHA still reports a string" do
    System.delete_env("GIT_SHA")

    assert health()["git_sha"] == "unknown"
  end

  test "the value tracks the ENV at request time, not at boot" do
    System.put_env("GIT_SHA", "aaaaaaa")
    assert health()["git_sha"] == "aaaaaaa"

    System.put_env("GIT_SHA", "bbbbbbb")
    assert health()["git_sha"] == "bbbbbbb"
  end
end
