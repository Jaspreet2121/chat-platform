defmodule AuthService.AuthClientHttpIntegrationTest do
  @moduledoc """
  Proves the Auth HTTP client adapter (`SharedInfra.AuthClientHttp`) round-trips over a REAL
  localhost listener and reconstructs the EXACT in-process shape (incl. `current_session`'s
  atom-keyed map) + maps transport failure to `{:error, :auth_unavailable}`. Tagged
  `:http_integration` (real Cowboy listener on a port) — EXCLUDED by default so the plain suite
  stays in-process + Docker-free. Run with `mix test --include http_integration`.
  """
  use ExUnit.Case, async: false

  @port 4191
  @token "test-internal-token"

  setup do
    prev_token = Application.get_env(:shared_infra, :internal_api_token)
    prev_url = Application.get_env(:shared_infra, :auth_service_url)
    Application.put_env(:shared_infra, :internal_api_token, @token)

    # Real internal HTTP listener for auth-service on a localhost port.
    start_supervised!(
      {Plug.Cowboy, scheme: :http, plug: AuthService.HTTP.Router, options: [port: @port]}
    )

    on_exit(fn ->
      if prev_token,
        do: Application.put_env(:shared_infra, :internal_api_token, prev_token),
        else: Application.delete_env(:shared_infra, :internal_api_token)

      if prev_url,
        do: Application.put_env(:shared_infra, :auth_service_url, prev_url),
        else: Application.delete_env(:shared_infra, :auth_service_url)
    end)

    :ok
  end

  @tag :http_integration
  test "current_session over HTTP == in-process (shape-identical, incl. atom keys)" do
    Application.put_env(:shared_infra, :auth_service_url, "http://localhost:#{@port}")
    attrs = %{"authorization" => "Bearer whatever"}

    assert SharedInfra.AuthClientHttp.current_session(attrs) ==
             AuthService.Sessions.current_session(attrs)
  end

  @tag :http_integration
  test "persistence_enabled? over HTTP == in-process (bare boolean round-trip)" do
    Application.put_env(:shared_infra, :auth_service_url, "http://localhost:#{@port}")

    assert SharedInfra.AuthClientHttp.persistence_enabled?() ==
             AuthService.Sessions.persistence_enabled?()
  end

  @tag :http_integration
  test "transport failure (no listener on the target port) → {:error, :auth_unavailable}" do
    Application.put_env(:shared_infra, :auth_service_url, "http://localhost:4199")
    attrs = %{"authorization" => "Bearer whatever"}

    assert SharedInfra.AuthClientHttp.current_session(attrs) == {:error, :auth_unavailable}
    # persistence_enabled? fails CLOSED (false, never a truthy error tuple).
    assert SharedInfra.AuthClientHttp.persistence_enabled?() == false
  end
end
