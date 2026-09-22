defmodule AuthService.RefreshGraceRaceTest do
  @moduledoc """
  THE GRACE WINDOW UNDER CONCURRENCY. A client whose response was lost often retries more than once,
  and the two retries can be in flight together. Without the advisory lock in `rotate_refresh_token`
  both would read the session row, both would mint, and both would write `refresh_token_hash` — the
  session ending up pointed at one token while a client holds the other.

  `:auto` sandbox mode, because two processes inside one transaction cannot contend for a lock. Every
  query here runs on its own connection and commits, which is the only way the race is real.

  NOT `AuthService.DataCase`, deliberately — it checks out a sandboxed connection, so the seed rows
  would live in the test process's uncommitted transaction and the Task processes, on their own
  connections, would not see them at all. The first version of this file did use it and failed
  intermittently with BOTH replays refused as `:refresh_invalid`, which is what an invisible user row
  looks like from inside `refresh/1`.
  """
  use ExUnit.Case, async: false

  alias AuthService.{DeviceSessions, RefreshTokens, Repo, Tokens}

  @tenant "00000000-0000-0000-0000-000000000001"

  setup do
    case Repo.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    # Both paths are behind their own persistence flag; without them Tokens.refresh/1 and
    # Tokens.revoke/1 answer from the placeholder branch and this suite proves nothing about the
    # database at all — which is exactly how it failed the first time it was run.
    previous = %{
      rotation: Application.get_env(:auth_service, :refresh_token_rotation_persistence, false),
      logout: Application.get_env(:auth_service, :logout_persistence, false)
    }

    Application.put_env(:auth_service, :refresh_token_rotation_persistence, true)
    Application.put_env(:auth_service, :logout_persistence, true)

    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    # EVERY ROW THIS SUITE WRITES IS COMMITTED — that is the point of :auto, and it means nothing
    # rolls back at the end of a test. The rows land in the one shared `chat_platform_test` database
    # that every other suite in the gate also uses, so they have to be removed explicitly. Leaving
    # them behind broke five unrelated message-service suites in the full run while every one of them
    # passed on its own, which is the most expensive shape a test-pollution bug has.
    #
    # Deleting the users is enough: refresh_tokens and device_sessions both cascade off users_auth.
    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
      Application.put_env(:auth_service, :refresh_token_rotation_persistence, previous.rotation)
      Application.put_env(:auth_service, :logout_persistence, previous.logout)
    end)

    :ok
  end

  defp seed_session! do
    user_id = Ecto.UUID.generate()
    on_exit(fn -> Repo.query!("DELETE FROM users_auth WHERE id = $1::text::uuid", [user_id]) end)
    device_id = "dev-#{System.unique_integer([:positive])}"
    raw = "grace-#{System.unique_integer([:positive])}"

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active', now(), now())",
      [user_id, @tenant, "+1555#{System.unique_integer([:positive])}"]
    )

    hash = Tokens.hash_token(raw)

    {:ok, session} =
      DeviceSessions.create_device_session(%{
        "user_id" => user_id,
        "device_id" => device_id,
        "platform" => "ios",
        "refresh_token_hash" => hash
      })

    {:ok, token} =
      RefreshTokens.create_refresh_token(%{
        "user_id" => user_id,
        "device_id" => device_id,
        "token_hash" => hash,
        "expires_at" => DateTime.add(DateTime.utc_now(), 2_592_000, :second)
      })

    %{user_id: user_id, device_id: device_id, raw: raw, session: session, token: token}
  end

  defp refresh(fixture, raw) do
    Tokens.refresh(%{"refresh_token" => raw, "device_id" => fixture.device_id})
  end

  @tag :postgres_integration
  test "two CONCURRENT replays of a just-rotated token both succeed and leave ONE consistent session" do
    fixture = seed_session!()

    # The rotation whose response is about to be "lost".
    assert {:ok, first} = refresh(fixture, fixture.raw)

    # Two retries of the ORIGINAL token, genuinely in flight together.
    tasks =
      for _ <- 1..2 do
        Task.async(fn -> refresh(fixture, fixture.raw) end)
      end

    results = Task.await_many(tasks, 15_000)

    assert Enum.all?(results, &match?({:ok, _}, &1)),
           "a concurrent grace replay was refused: #{inspect(results)}"

    issued = for {:ok, pair} <- results, do: pair.refresh_token

    # Distinct pairs — the lost one cannot be reproduced, only its hash was stored.
    assert length(Enum.uniq(issued)) == 2
    refute first.refresh_token in issued

    # THE SESSION IS INTACT AND POINTS AT EXACTLY ONE of the tokens actually issued. Without the
    # advisory lock the two writers interleave and it can end up naming a token neither client holds.
    session = DeviceSessions.get_device_session(fixture.user_id, fixture.device_id)
    assert session.revoked_at == nil

    all_hashes = Enum.map([first.refresh_token | issued], &Tokens.hash_token/1)
    assert session.refresh_token_hash in all_hashes
  end

  @tag :postgres_integration
  test "the chain pointer is written ONCE — a grace replay never re-stamps the predecessor" do
    fixture = seed_session!()
    assert {:ok, _first} = refresh(fixture, fixture.raw)

    original = RefreshTokens.get_by_token_hash(Tokens.hash_token(fixture.raw))
    revoked_at = original.revoked_at
    replaced_by = original.replaced_by_token_id

    assert {:ok, _second} = refresh(fixture, fixture.raw)

    after_grace = RefreshTokens.get_by_token_hash(Tokens.hash_token(fixture.raw))

    # Re-stamping revoked_at would slide the window forward on every retry — a token replayable for
    # as long as somebody kept replaying it.
    assert after_grace.revoked_at == revoked_at
    assert after_grace.replaced_by_token_id == replaced_by
  end

  @tag :postgres_integration
  test "LOGOUT refuses a grace-eligible token — signing out means signed out" do
    fixture = seed_session!()
    assert {:ok, _} = refresh(fixture, fixture.raw)

    # The predecessor is inside the window, so REFRESH would take it. Logout must not: it would
    # revoke a row that is no longer the session's and leave the live token alive.
    assert {:error, :refresh_invalid} =
             Tokens.revoke(%{"refresh_token" => fixture.raw, "device_id" => fixture.device_id})

    session = DeviceSessions.get_device_session(fixture.user_id, fixture.device_id)
    assert session.revoked_at == nil
  end
end
