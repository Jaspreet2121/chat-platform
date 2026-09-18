defmodule SharedInfra.RateLimiterDeploymentTest do
  @moduledoc """
  A SERVICE THAT CALLS THE RATE LIMITER MUST BE GIVEN A REDIS.

  This is the guard for the actual root cause of the stranger-first-message outage. The code was
  fine; the deployment was not. message-service became the first thing in its container to call
  `SharedInfra.RateLimiter` when the message-request budget shipped, and nothing gave that container
  a `REDIS_URL`. `config/runtime.exs` falls back to `redis://localhost:6379/0`, which inside that
  container is nothing at all, so every budget check returned unavailable — and with the then
  fail-closed policy, every stranger's FIRST message was refused at 0 of 3 with nothing stored.

  No test could have caught it, because every test pins the in-memory adapter. The gap was between
  the code and the compose file, so the check has to look at both.

  It reads the source tree rather than a hardcoded list: add a limiter call to a new service and this
  fails until that service is given a Redis, which is the order those two things should happen in.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../../..", __DIR__)
  @compose "docker-compose.prod.yml"

  # umbrella app → the service name it is deployed as. realtime_gateway maps to `gateway` because it
  # runs INSIDE the gateway's OS process — one release, one container, so the gateway's REDIS_URL is
  # its REDIS_URL. That entry was missing when this test was first written and the test found it,
  # which is the behaviour wanted: a limiter caller with nowhere to be deployed is a question, not a
  # silent pass.
  @deployed_as %{
    "api_gateway" => "gateway",
    "realtime_gateway" => "gateway",
    "auth_service" => "auth",
    "user_service" => "user",
    "conversation_service" => "conversation",
    "message_service" => "message",
    "media_service" => "media",
    "notification_service" => "notification"
  }

  defp apps_calling_the_limiter do
    @repo_root
    |> Path.join("apps/backend/apps/*/lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.filter(&(File.read!(&1) =~ "SharedInfra.RateLimiter"))
    |> Enum.map(fn path ->
      path |> Path.relative_to(Path.join(@repo_root, "apps/backend/apps")) |> Path.split() |> hd()
    end)
    |> Enum.uniq()
    # shared_infra DEFINES the limiter; it is a library with no container of its own.
    |> Enum.reject(&(&1 == "shared_infra"))
    |> Enum.sort()
  end

  # The environment block of one compose service, as raw text. A YAML parser would be the tidy answer
  # and is not worth a dependency for one assertion — the block boundary is unambiguous here because
  # every service is indented exactly two spaces.
  defp service_block(name) do
    text = File.read!(Path.join(@repo_root, @compose))
    [_, after_header] = String.split(text, "\n  #{name}:\n", parts: 2)

    after_header
    |> String.split(~r/\n  [a-z_-]+:\n/, parts: 2)
    |> hd()
  end

  test "every service whose code calls the rate limiter is given a REDIS_URL in compose" do
    callers = apps_calling_the_limiter()

    assert "message_service" in callers,
           "expected message_service to still call the limiter (the request budget) — if that moved, " <>
             "update this test rather than deleting it"

    for app <- callers do
      service =
        Map.get(@deployed_as, app) ||
          flunk("#{app} calls the rate limiter but this test does not know what it deploys as")

      block = service_block(service)

      assert block =~ "REDIS_URL",
             "#{app} calls SharedInfra.RateLimiter but the `#{service}` service in #{@compose} has " <>
               "no REDIS_URL. runtime.exs will fall back to redis://localhost:6379/0, which inside " <>
               "that container reaches nothing, and every limiter call will return unavailable. " <>
               "That is exactly how a stranger's first message came to be refused in production."
    end
  end

  test "the services that already had one still do — nobody loses a Redis by accident" do
    for service <- ["gateway", "notification", "message"] do
      assert service_block(service) =~ "REDIS_URL", "#{service} lost its REDIS_URL"
    end
  end
end
