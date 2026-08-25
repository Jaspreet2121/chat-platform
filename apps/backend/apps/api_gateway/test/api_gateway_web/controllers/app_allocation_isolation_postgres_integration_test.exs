defmodule ApiGatewayWeb.AppAllocationIsolationPostgresIntegrationTest do
  @moduledoc """
  The B2C allocation acceptance suite, end-to-end on real SQL and the REAL gateway endpoint:

    * allocation through the developer routes — cap 3 (the 4th create is 403 app.limit_reached),
      rename owner-gated, list shows only the caller's apps;
    * THE APP CLAIM FLOWS END-TO-END — a session minted for a freshly allocated app carries that
      app through Sessions.current_session into every directory surface, and the tenant-zero
      fallback fires ONLY for a token with no app claim (legacy sessions) — both directions
      mutation-proven against sessions.ex's `app_id_or_default(claims["app"])`;
    * ISOLATION between two freshly allocated integrators — a user in app A is invisible to app B
      via search, by-username, by-phone (the three directory legs) and the nearby store.

  Cross-repo rule: this suite runs in the sandbox's AUTOMATIC mode (no checkout — real commits,
  the scylla-suite precedent), NOT per-repo sandbox transactions. The same app/user ids must exist
  through BOTH AuthService.Repo and UserService.Repo (FKs on each side), and two uncommitted
  transactions inserting the same primary key BLOCK each other until the pool times out — observed
  as "tcp send: closed". Real commits make the mirror writes visible everywhere; all fixture data
  is per-run unique, and the postgres gate rebuilds the whole test DB every run.
  """
  use ExUnit.Case, async: false

  import Plug.Test

  alias AuthService.Apps
  alias AuthService.Repo, as: AuthRepo
  alias AuthService.Schemas.DeviceSession
  alias AuthService.Sessions
  alias AuthService.Tokens
  alias UserService.Repo, as: UserRepo

  @tenant_zero "00000000-0000-0000-0000-000000000001"

  setup_all do
    start_repo!(AuthRepo)
    start_repo!(UserRepo)

    # Auto-mode commits are REAL: sweep this suite's rows afterwards so later suites' GLOBAL
    # assertions (auth_controller's count(users_auth) == 1) see the table they expect. Every row
    # this suite creates is namespaced — phones +1777…, app names "IsoSuite …" (slugified to
    # isosuite-…) — so the sweep can never touch another suite's data.
    on_exit(fn ->
      ids = "SELECT id FROM users_auth WHERE phone_number LIKE '+1777%'"

      for sql <- [
            "DELETE FROM nearby_presence WHERE user_id IN (#{ids})",
            "DELETE FROM user_profiles WHERE user_id IN (#{ids})",
            "DELETE FROM device_sessions WHERE user_id IN (#{ids})",
            "DELETE FROM app_owners WHERE owner_user_id IN (#{ids})",
            "DELETE FROM users_auth WHERE phone_number LIKE '+1777%'",
            "DELETE FROM apps WHERE slug LIKE 'isosuite-%'"
          ] do
        AuthRepo.query!(sql, [])
      end
    end)

    :ok
  end

  setup do
    flags = [
      {:auth_service, :session_persistence},
      {:user_service, :user_profile_persistence}
    ]

    prev = for {app, key} <- flags, do: {app, key, Application.get_env(app, key, false)}
    for {app, key} <- flags, do: Application.put_env(app, key, true)
    on_exit(fn -> for {app, key, value} <- prev, do: Application.put_env(app, key, value) end)

    start_repo!(AuthRepo)
    start_repo!(UserRepo)

    :ok
  end

  @tag :postgres_integration
  test "developer routes: cap 3 with 403 on the 4th, list is caller-scoped, rename owner-gated" do
    owner = session_fixture!()
    other = session_fixture!()

    created =
      for n <- 1..3 do
        conn = post_json(owner.token, "/api/v1/developer/apps", %{"name" => "IsoSuite Cap #{n}"})
        assert conn.status == 201
        Jason.decode!(conn.resp_body)
      end

    for app <- created do
      assert app["mode"] == "live"
      refute app["app_id"] == @tenant_zero
    end

    # Distinct app_ids per allocation (allocation is create-new, idempotence lives at the twin).
    assert created |> Enum.map(& &1["app_id"]) |> Enum.uniq() |> length() == 3

    conn = post_json(owner.token, "/api/v1/developer/apps", %{"name" => "IsoSuite Cap 4"})
    assert conn.status == 403
    assert %{"error" => %{"code" => "app.limit_reached"}} = Jason.decode!(conn.resp_body)

    # The list is the CALLER's apps only.
    conn = get_authed(other.token, "/api/v1/developer/apps")
    assert %{"apps" => []} = Jason.decode!(conn.resp_body)

    conn = get_authed(owner.token, "/api/v1/developer/apps")
    assert %{"apps" => apps} = Jason.decode!(conn.resp_body)
    assert length(apps) == 3

    # Rename: owner 200; a stranger gets the SAME 403 as a nonexistent app (no existence leak).
    [%{"app_id" => app_id} | _] = created

    conn =
      patch_json(owner.token, "/api/v1/developer/apps/#{app_id}", %{"name" => "IsoSuite Renamed"})

    assert conn.status == 200
    assert %{"name" => "IsoSuite Renamed"} = Jason.decode!(conn.resp_body)

    conn = patch_json(other.token, "/api/v1/developer/apps/#{app_id}", %{"name" => "Hijack"})
    assert conn.status == 403

    conn =
      patch_json(other.token, "/api/v1/developer/apps/#{Ecto.UUID.generate()}", %{"name" => "x"})

    assert conn.status == 403
  end

  @tag :postgres_integration
  test "APP CLAIM: a fresh app's claim rides current_session; a claim-less token lands tenant-zero" do
    owner = session_fixture!()

    {:ok, %{app_id: fresh_app}} =
      Apps.create_app(%{"owner_user_id" => owner.user_id, "name" => "IsoSuite Claims"})

    # An end-user OF THE FRESH APP with a session minted for it (the allocated-app claim path).
    member = session_fixture!(app_id: fresh_app)

    assert {:ok, session} =
             Sessions.current_session(%{"authorization" => "Bearer " <> member.token})

    assert session.app_id == fresh_app

    # LEGACY: a token with NO app claim (pre-multi-tenancy sessions) still lands on tenant-zero.
    assert {:ok, legacy} =
             Sessions.current_session(%{"authorization" => "Bearer " <> owner.token})

    assert legacy.app_id == @tenant_zero
  end

  @tag :postgres_integration
  test "ISOLATION: a user in fresh app A is invisible to fresh app B on every directory surface" do
    owner_a = session_fixture!()
    owner_b = session_fixture!()

    {:ok, %{app_id: app_a}} =
      Apps.create_app(%{"owner_user_id" => owner_a.user_id, "name" => "IsoSuite A"})

    {:ok, %{app_id: app_b}} =
      Apps.create_app(%{"owner_user_id" => owner_b.user_id, "name" => "IsoSuite B"})

    a_phone = unique_phone()
    b_phone = unique_phone()
    a_peer = directory_user!(app_a, "Asha Sharma", "asha_a", a_phone)
    b_peer = directory_user!(app_b, "Asha Verma", "asha_b", b_phone)

    # Callers: one session in each app (users mirrored into AuthRepo by session_fixture!).
    caller_a = session_fixture!(app_id: app_a)
    caller_b = session_fixture!(app_id: app_b)

    # 1) SEARCH — the same "Asha" query answers per-app, never across.
    assert search_ids(caller_a.token, "Asha") == [a_peer]
    assert search_ids(caller_b.token, "Asha") == [b_peer]

    # 2) BY-USERNAME — B's handle does not exist in A's namespace (404), A's own resolves.
    assert get_authed(caller_a.token, "/api/v1/users/by-username/asha_b").status == 404
    conn = get_authed(caller_a.token, "/api/v1/users/by-username/asha_a")
    assert conn.status == 200
    assert %{"user_id" => ^a_peer} = Jason.decode!(conn.resp_body)

    # 3) BY-PHONE — B's number is unreachable from A; A's own resolves. (encode: '+' is not a
    # query-string literal)
    assert get_authed(
             caller_a.token,
             "/api/v1/users/by-phone?phone=#{URI.encode_www_form(b_phone)}"
           ).status == 404

    conn =
      get_authed(caller_a.token, "/api/v1/users/by-phone?phone=#{URI.encode_www_form(a_phone)}")

    assert conn.status == 200
    assert %{"user_id" => ^a_peer} = Jason.decode!(conn.resp_body)

    # 4) NEARBY (store level; the gateway leg is stub-proven in NearbyControllerTest) — both peers
    # broadcast at the SAME coordinates in their own apps; discovery never crosses the seal.
    for {user, app} <- [{a_peer, app_a}, {b_peer, app_b}] do
      assert {:ok, _} =
               UserService.Nearby.discover(%{
                 "user_id" => user,
                 "app_id" => app,
                 "latitude" => 28.6139,
                 "longitude" => 77.2090,
                 "accuracy_m" => 10,
                 "radius_m" => 200
               })
    end

    a_viewer = directory_user!(app_a, "Viewer A", "viewer_a", unique_phone())

    assert {:ok, %{people: people}} =
             UserService.Nearby.discover(%{
               "user_id" => a_viewer,
               "app_id" => app_a,
               "latitude" => 28.6139,
               "longitude" => 77.2090,
               "accuracy_m" => 10,
               "radius_m" => 200
             })

    assert Enum.map(people, & &1.user_id) == [a_peer]
  end

  # ---- fixtures ----------------------------------------------------------------------------------

  # A user + device session + signed access token. `app_id:` mints the token WITH the app claim
  # (and stamps the users_auth row into that app, mirrored into BOTH repos); without it the token
  # carries NO app claim — the legacy shape the tenant-zero fallback exists for.
  defp session_fixture!(opts \\ []) do
    app_id = Keyword.get(opts, :app_id)
    user_id = Ecto.UUID.generate()
    session_id = Ecto.UUID.generate()
    device_id = "iso-device-#{System.unique_integer([:positive])}"
    phone = unique_phone()

    AuthRepo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, password_hash, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, COALESCE($2::text::uuid, '#{@tenant_zero}'::uuid), $3, 'x', 'active', now(), now())",
      [user_id, app_id, phone]
    )

    {:ok, _} =
      %DeviceSession{}
      |> DeviceSession.changeset(%{
        "id" => session_id,
        "user_id" => user_id,
        "device_id" => device_id,
        "device_name" => "Iso Device",
        "platform" => "ios",
        "refresh_token_hash" => Tokens.hash_token("iso-refresh-#{device_id}"),
        "last_seen_at" => DateTime.utc_now()
      })
      |> AuthRepo.insert()

    now = DateTime.utc_now()

    claims =
      %{
        "typ" => "access",
        "sub" => user_id,
        "sid" => session_id,
        "did" => device_id,
        "iat" => DateTime.to_unix(now),
        "exp" => DateTime.to_unix(DateTime.add(now, Tokens.access_token_ttl_seconds(), :second)),
        "jti" => Ecto.UUID.generate()
      }
      |> then(fn claims ->
        if app_id, do: Map.put(claims, "app", app_id), else: claims
      end)

    {:ok, token} = Tokens.sign_claims(claims)
    %{user_id: user_id, token: token}
  end

  # A directory-visible member of `app_id`: one committed users_auth row (both services read the
  # same database in automatic mode) + the profile row with the handle.
  defp directory_user!(app_id, display_name, username, phone) do
    id = Ecto.UUID.generate()

    UserRepo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, password_hash, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', 'active', now(), now())",
      [id, app_id, phone]
    )

    UserRepo.query!(
      "INSERT INTO user_profiles (user_id, app_id, display_name, username, username_key, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, $4, lower($4), now(), now())",
      [id, app_id, display_name, username]
    )

    id
  end

  defp search_ids(token, q) do
    conn = get_authed(token, "/api/v1/users/search?q=#{URI.encode_www_form(q)}")
    assert conn.status == 200
    %{"users" => users} = Jason.decode!(conn.resp_body)
    Enum.map(users, & &1["user_id"])
  end

  defp get_authed(token, path) do
    :get
    |> conn(path)
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
    |> ApiGatewayWeb.Endpoint.call([])
  end

  defp post_json(token, path, params), do: json_request(:post, token, path, params)
  defp patch_json(token, path, params), do: json_request(:patch, token, path, params)

  defp json_request(method, token, path, params) do
    method
    |> conn(path, Jason.encode!(params))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
    |> ApiGatewayWeb.Endpoint.call([])
  end

  defp unique_phone, do: "+1777#{System.unique_integer([:positive])}"

  defp start_repo!(repo) do
    case repo.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _}} ->
        :ok
    end
  end
end
