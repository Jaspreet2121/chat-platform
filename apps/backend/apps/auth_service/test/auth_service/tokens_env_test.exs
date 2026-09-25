defmodule AuthService.TokensEnvTest do
  @moduledoc """
  The session and grace lifetimes come from the environment, and the environment is allowed to be
  EMPTY: the compose file passes them through as `${VAR:-}`, so an unset .env value arrives in the
  container as "" — and "" must mean "use the default", never 0. A zero-second session would sign
  everyone out on arrival; a zero-second remember-me would do it silently. Junk and zero are unset
  too; a real value wins.
  """
  use ExUnit.Case, async: false

  alias AuthService.Tokens

  @vars ~w(AUTH_SESSION_TTL_SECONDS AUTH_SESSION_REMEMBER_TTL_SECONDS AUTH_REFRESH_GRACE_SECONDS)

  setup do
    previous = Map.new(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end
    end)

    :ok
  end

  test "an EMPTY string is unset — the defaults, never 0" do
    for var <- @vars, do: System.put_env(var, "")

    assert Tokens.session_ttl_seconds(false) == 10_800
    assert Tokens.session_ttl_seconds(true) == 604_800
    assert Tokens.refresh_grace_seconds() == 30
  end

  test "junk and zero session TTLs are unset too" do
    for value <- ["abc", "0", "-5", " "] do
      System.put_env("AUTH_SESSION_TTL_SECONDS", value)
      System.put_env("AUTH_SESSION_REMEMBER_TTL_SECONDS", value)
      assert Tokens.session_ttl_seconds(false) == 10_800, "session TTL #{inspect(value)}"
      assert Tokens.session_ttl_seconds(true) == 604_800, "remember TTL #{inspect(value)}"
    end
  end

  test "a real value wins — this is what the .env lines are for" do
    System.put_env("AUTH_SESSION_TTL_SECONDS", "900")
    System.put_env("AUTH_SESSION_REMEMBER_TTL_SECONDS", "900")
    System.put_env("AUTH_REFRESH_GRACE_SECONDS", "45")

    assert Tokens.session_ttl_seconds(false) == 900
    assert Tokens.session_ttl_seconds(true) == 900
    assert Tokens.refresh_grace_seconds() == 45
  end

  test "the grace window may be taken to ZERO on purpose, but empty is still the default" do
    # Zero is a legitimate setting here (it restores the pre-grace behaviour). Empty is not zero.
    System.put_env("AUTH_REFRESH_GRACE_SECONDS", "0")
    assert Tokens.refresh_grace_seconds() == 0

    System.put_env("AUTH_REFRESH_GRACE_SECONDS", "")
    assert Tokens.refresh_grace_seconds() == 30
  end
end
