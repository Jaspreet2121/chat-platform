defmodule ApiGatewayWeb.UserSearchControllerTest do
  @moduledoc """
  GET /api/v1/users/search — the gateway half of the 098 directory search, no DB: session gate, the
  §7 error envelope (search.query_too_short — the /search/messages code), the 1..50 limit clamp, the
  per-row ProfilePresenter pass (app_id NEVER reaches the client; a hidden avatar redacts exactly
  like by-phone), the 30/min fail-CLOSED rate limit with Retry-After, and the caller's app_id/user_id
  riding into the store attrs.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.UserController

  @caller "11111111-1111-1111-1111-111111111111"
  @found "22222222-2222-2222-2222-222222222222"
  @app "44444444-4444-4444-8444-444444444444"

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer " <> user}),
      do: {:ok, %{user_id: user, app_id: "44444444-4444-4444-8444-444444444444"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule UserClientStub do
    @moduledoc false
    # Captures the search attrs (limit clamp / scoping assertions) and returns one card whose app_id
    # MUST be stripped by the presenter before the response.
    def search_users(attrs) do
      send(:user_search_collector, {:search_attrs, attrs})

      {:ok,
       %{
         users: [
           %{
             user_id: "22222222-2222-2222-2222-222222222222",
             display_name: "Found User",
             username: "found",
             avatar_media_id: nil,
             avatar_object_key: nil,
             app_id: attrs["app_id"],
             bio: nil
           }
         ]
       }}
    end

    # Presenter's photo-visibility read: everyone → the avatar (none here) is permitted.
    def get_privacy(_attrs), do: {:ok, %{profile_photo_visibility: "everyone"}}
  end

  defmodule ConversationStub do
    @moduledoc false
    def either_blocked?(_attrs), do: {:ok, %{blocked: false}}
  end

  defmodule LimiterOk do
    @moduledoc false
    def check_rate(_attrs), do: :ok
  end

  defmodule LimiterTrips do
    @moduledoc false
    def check_rate(_attrs), do: {:error, :rate_limited, 42}
  end

  defmodule LimiterDown do
    @moduledoc false
    def check_rate(_attrs), do: {:error, :redis_down}
  end

  setup do
    Process.register(self(), :user_search_collector)

    keys = [
      auth_client_adapter: AuthStub,
      user_client_adapter: UserClientStub,
      conversation_client_adapter: ConversationStub,
      rate_limiter_adapter: LimiterOk
    ]

    prev = for {k, _} <- keys, into: %{}, do: {k, Application.get_env(:shared_infra, k)}
    for {k, v} <- keys, do: Application.put_env(:shared_infra, k, v)

    on_exit(fn ->
      for {k, v} <- prev do
        if v,
          do: Application.put_env(:shared_infra, k, v),
          else: Application.delete_env(:shared_infra, k)
      end
    end)

    :ok
  end

  defp request(params, user \\ @caller) do
    :get
    |> conn("/api/v1/users/search", params)
    |> put_req_header("authorization", "Bearer " <> user)
    |> UserController.search(params)
  end

  test "a match comes back as the presenter card — app_id stripped, avatar_url explicit" do
    conn = request(%{"q" => "fou"})
    assert conn.status == 200

    %{"users" => [card]} = Jason.decode!(conn.resp_body)
    assert card["user_id"] == @found
    assert card["display_name"] == "Found User"
    assert card["username"] == "found"
    # The presenter's contract: the internal tenant id never reaches the client; no-avatar is an
    # EXPLICIT null (same shape as a redacted one — by-phone parity).
    refute Map.has_key?(card, "app_id")
    assert Map.has_key?(card, "avatar_url") and is_nil(card["avatar_url"])

    # The store attrs carried the SESSION's tenant + caller and the default limit.
    assert_receive {:search_attrs, attrs}
    assert attrs["app_id"] == @app
    assert attrs["caller_user_id"] == @caller
    assert attrs["q"] == "fou"
    assert attrs["limit"] == 20
  end

  test "q is trimmed; under 3 chars → 400 search.query_too_short in the standard envelope" do
    for q <- ["ab", "  ab  ", "", "  "] do
      conn = request(%{"q" => q})
      assert conn.status == 400
      assert %{"error" => %{"code" => "search.query_too_short"}} = Jason.decode!(conn.resp_body)
    end

    # Trimming that still leaves >= 3 passes.
    assert request(%{"q" => "  fou  "}).status == 200
    assert_receive {:search_attrs, %{"q" => "fou"}}
  end

  test "limit clamps to 1..50 (default 20; strings parsed)" do
    request(%{"q" => "fou", "limit" => "999"})
    assert_receive {:search_attrs, %{"limit" => 50}}

    request(%{"q" => "fou", "limit" => "0"})
    assert_receive {:search_attrs, %{"limit" => 1}}

    request(%{"q" => "fou", "limit" => "garbage"})
    assert_receive {:search_attrs, %{"limit" => 20}}
  end

  test "rate limited → 429 with Retry-After; limiter outage FAILS CLOSED → 503" do
    Application.put_env(:shared_infra, :rate_limiter_adapter, LimiterTrips)
    conn = request(%{"q" => "fou"})
    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") == ["42"]
    assert %{"error" => %{"code" => "user.search_rate_limited"}} = Jason.decode!(conn.resp_body)

    Application.put_env(:shared_infra, :rate_limiter_adapter, LimiterDown)
    conn = request(%{"q" => "fou"})
    assert conn.status == 503
    assert get_resp_header(conn, "retry-after") == ["30"]
  end

  test "no session → 401; a too-short q never reaches the limiter or the store" do
    conn =
      :get
      |> conn("/api/v1/users/search", %{"q" => "fou"})
      |> UserController.search(%{"q" => "fou"})

    assert conn.status == 401

    Application.put_env(:shared_infra, :rate_limiter_adapter, LimiterTrips)
    conn = request(%{"q" => "ab"})
    # Validation precedes the limiter: still the 400, not a 429 — and no store call happened.
    assert conn.status == 400
    refute_receive {:search_attrs, _}, 50
  end
end
