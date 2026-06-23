defmodule AuthService.AuthClientInProcessTest do
  @moduledoc """
  Sanity that the default `SharedInfra.AuthClient` adapter delegates FAITHFULLY to
  `AuthService.*` — same input, same result. This is the zero-behavior-change guarantee for
  routing the edge apps through the client boundary. Plain, Docker-free (session persistence
  is off by default → the placeholder path, no Repo).
  """
  use ExUnit.Case, async: true

  test "default adapter is the in-process adapter" do
    assert SharedInfra.AuthClient.adapter() == AuthService.AuthClientInProcess
  end

  test "current_session through the client == calling AuthService.Sessions directly" do
    attrs = %{"authorization" => "Bearer whatever"}

    assert SharedInfra.AuthClient.current_session(attrs) ==
             AuthService.Sessions.current_session(attrs)
  end

  test "persistence_enabled? through the client == AuthService.Sessions directly" do
    assert SharedInfra.AuthClient.persistence_enabled?() ==
             AuthService.Sessions.persistence_enabled?()
  end
end
