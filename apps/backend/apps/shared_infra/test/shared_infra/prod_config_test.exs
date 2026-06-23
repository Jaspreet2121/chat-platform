defmodule SharedInfra.ProdConfigTest do
  @moduledoc """
  Proves the prod fail-fast guard logic WITHOUT booting MIX_ENV=prod: the guard is a pure
  function over env vars, so we exercise it directly (plain, Docker-free).
  """
  use ExUnit.Case, async: true

  alias SharedInfra.ProdConfig

  @var "PROD_CONFIG_TEST_SECRET"

  setup do
    on_exit(fn -> System.delete_env(@var) end)
    :ok
  end

  describe "placeholder?/1" do
    test "flags the known insecure dev/test defaults" do
      assert ProdConfig.placeholder?("local-token-secret-change-before-production")
      assert ProdConfig.placeholder?("local-otp-secret-change-before-production")
      assert ProdConfig.placeholder?("development-placeholder-change-before-production-...")
      assert ProdConfig.placeholder?("test-placeholder-change-before-production-test-...")
    end

    test "accepts a real-looking secret" do
      refute ProdConfig.placeholder?("3kJ2f9aQ_real_strong_secret_value_8f1bc0")
    end
  end

  describe "require_secret!/1" do
    test "raises when the env var is unset" do
      System.delete_env(@var)
      assert_raise RuntimeError, ~r/is not set/, fn -> ProdConfig.require_secret!(@var) end
    end

    test "raises when the env var is blank" do
      System.put_env(@var, "")
      assert_raise RuntimeError, ~r/is not set/, fn -> ProdConfig.require_secret!(@var) end
    end

    test "raises when set to a known insecure placeholder" do
      System.put_env(@var, "local-token-secret-change-before-production")
      assert_raise RuntimeError, ~r/insecure placeholder/, fn -> ProdConfig.require_secret!(@var) end
    end

    test "returns the value when it is a real secret" do
      System.put_env(@var, "a-real-strong-production-secret")
      assert ProdConfig.require_secret!(@var) == "a-real-strong-production-secret"
    end
  end

  describe "require_present!/1" do
    test "raises when unset" do
      System.delete_env(@var)
      assert_raise RuntimeError, ~r/is not set/, fn -> ProdConfig.require_present!(@var) end
    end

    test "returns the value when present (no placeholder check)" do
      System.put_env(@var, "postgres://user:pass@host/db")
      assert ProdConfig.require_present!(@var) == "postgres://user:pass@host/db"
    end
  end
end
