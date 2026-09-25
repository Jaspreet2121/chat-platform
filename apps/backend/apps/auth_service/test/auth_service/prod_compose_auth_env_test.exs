defmodule AuthService.ProdComposeAuthEnvTest do
  @moduledoc """
  Every environment variable tokens.ex reads must be passed to the auth container by
  docker-compose.prod.yml — as `${VAR:-}`, so an unset .env value arrives as "" (which tokens.ex
  treats as the default).

  This is the drift that bit on 2026-09-25: AUTH_SESSION_TTL_SECONDS was set in .env, the auth
  container was recreated, and login still answered 10800, because the compose file never listed
  the variable and compose passes through nothing it is not told to. The list of variables is read
  from tokens.ex ITSELF, so a fourth one added there fails here until the compose file knows it.
  """
  use ExUnit.Case, async: true

  @tokens Path.expand("../../lib/auth_service/tokens.ex", __DIR__)
  @compose Path.expand("../../../../../../docker-compose.prod.yml", __DIR__)

  defp vars_read_by_tokens do
    ~r/env_int(?:_or_zero)?\("([A-Z_]+)"/
    |> Regex.scan(File.read!(@tokens), capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp auth_block do
    [block] =
      Regex.run(~r/\n  auth:\n(.*?)\n  [a-z]+:\n/s, File.read!(@compose), capture: :all_but_first)

    block
  end

  test "tokens.ex reads the three lifetime variables (the list this test guards)" do
    assert Enum.sort(vars_read_by_tokens()) ==
             ~w(AUTH_REFRESH_GRACE_SECONDS AUTH_SESSION_REMEMBER_TTL_SECONDS AUTH_SESSION_TTL_SECONDS)
  end

  test "each one is passed to the auth container as ${VAR:-}" do
    block = auth_block()

    for var <- vars_read_by_tokens() do
      assert block =~ ~r/^\s+#{var}: \$\{#{var}:-\}$/m,
             "#{var} is read by tokens.ex but not passed through in docker-compose.prod.yml's auth block"
    end
  end
end
