defmodule UserService.UserClientInProcessTest do
  @moduledoc """
  Sanity that the default `SharedInfra.UserClient` adapter delegates FAITHFULLY to
  `UserService.Profiles` — same input, same result (the zero-behavior-change guarantee for
  routing edge apps through the client boundary). Plain, Docker-free (profile persistence is
  off by default → the placeholder path, no Repo).
  """
  use ExUnit.Case, async: true

  test "default adapter is the in-process adapter" do
    assert SharedInfra.UserClient.adapter() == UserService.UserClientInProcess
  end

  test "get_public_profile through the client == calling UserService.Profiles directly" do
    attrs = %{"user_id" => "user_123"}

    assert SharedInfra.UserClient.get_public_profile(attrs) ==
             UserService.Profiles.get_public_profile(attrs)
  end
end
