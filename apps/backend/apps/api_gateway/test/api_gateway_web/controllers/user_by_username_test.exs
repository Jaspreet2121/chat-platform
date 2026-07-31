defmodule ApiGatewayWeb.UserByUsernameTest do
  @moduledoc """
  By-username discovery + availability (Docker-free; Auth/User/Conversation clients stubbed). Proves:
  the by-username response is BYTE-IDENTICAL to by-phone's for the same target (both run ProfilePresenter
  — asserted against the REAL by_phone response, so the redaction paths cannot drift), including for a
  photo-HIDDEN target; unknown handle → 404 with no distinction; self → 409 (by-phone parity); the
  availability endpoint is session-authed + rate-limited (429 + retry-after via the in-memory limiter)
  and relays the availability codes; PATCH /me maps each username failure to its usernames.* code; a
  user with no username has an unchanged card (username: null, never "@null" server-side).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.UserController

  defmodule AuthStub do
    @me "11111111-1111-4111-8111-111111111111"
    @target "22222222-2222-4222-8222-222222222222"

    def current_session(%{"authorization" => "Bearer me"}),
      do: {:ok, %{user_id: @me, app_id: "app1"}}

    def current_session(_), do: {:error, :session_invalid}

    # by-phone's resolver: the SAME target the username resolves to (the parity pair).
    def lookup_user_by_phone(%{"phone_number" => "+15551230001"}), do: {:ok, %{user_id: @target}}
    def lookup_user_by_phone(_), do: {:error, :not_found}
  end

  defmodule UserStub do
    @me "11111111-1111-4111-8111-111111111111"
    @target "22222222-2222-4222-8222-222222222222"
    @bare "33333333-3333-4333-8333-333333333333"

    def lookup_by_username(%{"username" => u, "app_id" => "app1"}) do
      case String.downcase(u) do
        "famous" -> {:ok, %{user_id: @target}}
        "bare" -> {:ok, %{user_id: @bare}}
        "myself" -> {:ok, %{user_id: @me}}
        _ -> {:error, :not_found}
      end
    end

    def get_public_profile(%{"user_id" => @target}),
      do:
        {:ok,
         %{
           user_id: @target,
           display_name: "Famous",
           username: "Famous",
           avatar_media_id: nil,
           bio: nil
         }}

    def get_public_profile(%{"user_id" => @bare}),
      do:
        {:ok,
         %{user_id: @bare, display_name: "Bare", username: nil, avatar_media_id: nil, bio: nil}}

    def get_public_profile(_), do: {:error, :profile_not_found}

    # Photo-visibility for ProfilePresenter: target hides from non-contacts (the redaction case).
    def get_privacy(%{"user_id" => @target}), do: {:ok, %{profile_photo_visibility: "nobody"}}
    def get_privacy(_), do: {:ok, %{profile_photo_visibility: "everyone"}}

    def check_username(%{"username" => "taken_name"}),
      do: {:ok, %{available: false, code: "username_taken"}}

    def check_username(_attrs), do: {:ok, %{available: true, code: nil}}

    def update_current_profile(%{"username" => "collide"}), do: {:error, :username_taken}
    def update_current_profile(%{"username" => "toooften"}), do: {:error, :username_change_limit}

    def update_current_profile(attrs),
      do: {:ok, %{user_id: attrs["user_id"], display_name: "X", username: attrs["username"]}}
  end

  defmodule ConvStub do
    def either_blocked?(_attrs), do: {:ok, %{blocked: false}}
    def shares_conversation?(_attrs), do: {:ok, %{shares: false}}
  end

  setup do
    prev = %{
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      user: Application.get_env(:shared_infra, :user_client_adapter),
      conv: Application.get_env(:shared_infra, :conversation_client_adapter),
      limiter: Application.get_env(:shared_infra, :rate_limiter_adapter),
      persistence: Application.get_env(:user_service, :user_profile_persistence)
    }

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)

    Application.put_env(
      :shared_infra,
      :rate_limiter_adapter,
      SharedInfra.RateLimiter.InMemoryAdapter
    )

    # PATCH /me must take the DB-backed path so the username error mapping is exercised.
    Application.put_env(:user_service, :user_profile_persistence, true)
    SharedInfra.RateLimiter.InMemoryAdapter.reset()

    on_exit(fn ->
      restore(:shared_infra, :auth_client_adapter, prev.auth)
      restore(:shared_infra, :user_client_adapter, prev.user)
      restore(:shared_infra, :conversation_client_adapter, prev.conv)
      restore(:shared_infra, :rate_limiter_adapter, prev.limiter)
      restore(:user_service, :user_profile_persistence, prev.persistence)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp authed(method, token \\ "me") do
    method |> conn("/x", %{}) |> put_req_header("authorization", "Bearer #{token}")
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "by-username == by-phone for the SAME target (real responses compared — redaction cannot drift)" do
    by_username =
      UserController.by_username(authed(:get), %{"username" => "Famous"})

    by_phone = UserController.by_phone(authed(:get), %{"phone" => "+15551230001"})

    assert by_username.status == 200
    assert by_phone.status == 200

    # Byte-identical: same ProfilePresenter, same redaction (the target hides their photo — both cards
    # carry avatar_url: null and NO avatar_media_id), same username passthrough.
    assert body(by_username) == body(by_phone)
    assert body(by_username)["avatar_url"] == nil
    refute Map.has_key?(body(by_username), "avatar_media_id")
    assert body(by_username)["username"] == "Famous"
  end

  test "unknown handle → one indistinguishable 404; self-lookup → 409 (by-phone parity)" do
    conn = UserController.by_username(authed(:get), %{"username" => "nobody_here"})
    assert conn.status == 404
    assert body(conn)["error"]["code"] == "user.username_not_found"

    self_conn = UserController.by_username(authed(:get), %{"username" => "myself"})
    assert self_conn.status == 409
  end

  test "a user with NO username: card unchanged, username is null (nothing can render @null server-side)" do
    conn = UserController.by_username(authed(:get), %{"username" => "bare"})
    assert conn.status == 200
    assert body(conn)["username"] == nil
    assert body(conn)["display_name"] == "Bare"
  end

  test "availability: relays codes; RATE-LIMITED per user with retry-after; 401 unauthenticated" do
    ok = UserController.username_availability(authed(:get), %{"username" => "fresh"})
    assert ok.status == 200
    assert body(ok) == %{"available" => true, "code" => nil}

    taken = UserController.username_availability(authed(:get), %{"username" => "taken_name"})
    assert body(taken) == %{"available" => false, "code" => "username_taken"}

    # Exhaust the 30/hour budget (2 used above) → the 31st call is 429 with retry-after.
    for _ <- 1..28 do
      assert UserController.username_availability(authed(:get), %{"username" => "fresh"}).status ==
               200
    end

    limited = UserController.username_availability(authed(:get), %{"username" => "fresh"})
    assert limited.status == 429
    assert body(limited)["error"]["code"] == "usernames.rate_limited"
    assert get_resp_header(limited, "retry-after") != []

    assert UserController.username_availability(authed(:get, "nobody"), %{"username" => "x"}).status ==
             401
  end

  test "PATCH /me maps username failures to their usernames.* codes" do
    for {value, code} <- [{"collide", "usernames.taken"}, {"toooften", "usernames.change_limit"}] do
      conn = UserController.update_me(authed(:patch), %{"username" => value})
      assert conn.status == 400
      assert body(conn)["error"]["code"] == code
    end

    ok = UserController.update_me(authed(:patch), %{"username" => "Fine_Name"})
    assert ok.status == 200
    assert body(ok)["username"] == "Fine_Name"
  end
end
