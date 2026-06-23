defmodule UserService.UserClientHttpIntegrationTest do
  @moduledoc """
  Proves the User HTTP client adapter (`SharedInfra.UserClientHttp`) round-trips over a REAL localhost
  listener and reconstructs the EXACT in-process shape (atom-keyed profile maps) + maps transport
  failure to `{:error, :user_unavailable}`. Tagged `:http_integration` (real Cowboy listener) —
  EXCLUDED by default so the plain suite stays in-process + Docker-free.
  """
  use ExUnit.Case, async: false

  @port 4193
  @token "test-internal-token"

  setup do
    prev_token = Application.get_env(:shared_infra, :internal_api_token)
    prev_url = Application.get_env(:shared_infra, :user_service_url)
    Application.put_env(:shared_infra, :internal_api_token, @token)

    start_supervised!(
      {Plug.Cowboy, scheme: :http, plug: UserService.HTTP.Router, options: [port: @port]}
    )

    on_exit(fn ->
      if prev_token,
        do: Application.put_env(:shared_infra, :internal_api_token, prev_token),
        else: Application.delete_env(:shared_infra, :internal_api_token)

      if prev_url,
        do: Application.put_env(:shared_infra, :user_service_url, prev_url),
        else: Application.delete_env(:shared_infra, :user_service_url)
    end)

    :ok
  end

  @tag :http_integration
  test "get_current_profile over HTTP == in-process (atom-keyed profile)" do
    Application.put_env(:shared_infra, :user_service_url, "http://localhost:#{@port}")
    attrs = %{"user_id" => "user_1"}

    assert SharedInfra.UserClientHttp.get_current_profile(attrs) ==
             UserService.Profiles.get_current_profile(attrs)
  end

  @tag :http_integration
  test "get_public_profile over HTTP == in-process" do
    Application.put_env(:shared_infra, :user_service_url, "http://localhost:#{@port}")
    attrs = %{"user_id" => "user_1"}

    assert SharedInfra.UserClientHttp.get_public_profile(attrs) ==
             UserService.Profiles.get_public_profile(attrs)
  end

  @tag :http_integration
  test "transport failure (no listener) → {:error, :user_unavailable}" do
    Application.put_env(:shared_infra, :user_service_url, "http://localhost:4197")

    assert SharedInfra.UserClientHttp.get_current_profile(%{"user_id" => "u"}) ==
             {:error, :user_unavailable}
  end
end
