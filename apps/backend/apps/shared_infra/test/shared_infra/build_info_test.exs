defmodule SharedInfra.BuildInfoTest do
  @moduledoc """
  The build's identity, as every /health response reports it.

  Two properties, and both are about not lying:

    * ALWAYS A STRING. A nil would make "which build is this?" answerable only by a consumer that
      handles nil — and a health payload whose key is sometimes missing is a key nobody trusts.
    * READ AT CALL TIME. A module attribute freezes whatever GIT_SHA was set when the module was
      COMPILED, which in a release is the build container, not the deployed one. The value would
      then be a confident, unfalsifiable lie about a different build.
  """
  use ExUnit.Case, async: false

  alias SharedInfra.BuildInfo

  setup do
    previous = System.get_env("GIT_SHA")

    on_exit(fn ->
      if previous, do: System.put_env("GIT_SHA", previous), else: System.delete_env("GIT_SHA")
    end)

    :ok
  end

  test "reports the SHA the image was built with" do
    System.put_env("GIT_SHA", "2cc6370")
    assert BuildInfo.git_sha() == "2cc6370"
  end

  test "NO env → the string \"unknown\", never nil" do
    System.delete_env("GIT_SHA")

    sha = BuildInfo.git_sha()

    assert is_binary(sha),
           "git_sha returned #{inspect(sha)} — every health payload would carry a null (or drop " <>
             "the key), and a build that forgot the arg would look like a broken endpoint"

    assert sha == "unknown"
  end

  test "an EMPTY env is also \"unknown\" — a blank build arg is a missing one" do
    System.put_env("GIT_SHA", "")
    assert BuildInfo.git_sha() == "unknown"
  end

  test "READ AT CALL TIME: a value set after this module loaded is still reflected" do
    # The module has been loaded and compiled long before this line runs. If the SHA were captured
    # into a module attribute, this is exactly the assertion that could not pass — and in prod the
    # captured value would be the BUILD container's env, reported forever as the deployed build.
    System.put_env("GIT_SHA", "deadbee")
    assert BuildInfo.git_sha() == "deadbee"

    System.put_env("GIT_SHA", "cafef00")

    assert BuildInfo.git_sha() == "cafef00",
           "the SHA was frozen at compile time — the endpoint reports whichever build compiled the " <>
             "module, not the one that is running"
  end
end
