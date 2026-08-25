defmodule ApiGatewayWeb.DatingControllerTest do
  @moduledoc """
  The gateway half of Dating (105), no DB: profile PATCH broadcasts dating_profile_changed; deck
  cards get PRESIGNED photo URLs (never raw ids, never coordinates); a like broadcasts
  dating_like_received to the target with a payload locked to the type alone (no ids — no oracle);
  a MATCH creates-or-gets the 1:1 through the ONE direct-conversation path, attaches it, answers
  {matched, match_id, conversation_id}, and broadcasts dating_matched to BOTH (payload locked); a
  pass broadcasts NOTHING; unmatch broadcasts dating_unmatched to both; the block hook
  auto-unmatches; error mapping (underage 403, incomplete 422, self-swipe 422, matched 409).
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.DatingController

  @me "11111111-1111-1111-1111-111111111111"
  @peer "22222222-2222-2222-2222-222222222222"
  @app "44444444-4444-4444-8444-444444444444"
  @match "99999999-9999-4999-8999-999999999999"

  defmodule AuthStub do
    def current_session(%{"authorization" => "Bearer token"}),
      do:
        {:ok,
         %{
           user_id: "11111111-1111-1111-1111-111111111111",
           app_id: "44444444-4444-4444-8444-444444444444"
         }}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule UserStub do
    def get_dating_profile(_attrs) do
      {:ok, %{enabled: true, dob: "1999-01-01", age: 27, gender: "woman", interested_in: ["man"]}}
    end

    def update_dating_profile(attrs) do
      send(:dating_test, {:update_profile, attrs})

      case Application.get_env(:api_gateway, :test_dating_update, :ok) do
        :ok -> {:ok, %{enabled: true, age: 27}}
        error -> error
      end
    end

    def dating_deck(attrs) do
      send(:dating_test, {:deck, attrs})

      {:ok,
       %{
         cards: [
           %{
             user_id: "22222222-2222-2222-2222-222222222222",
             display_name: "Asha",
             age: 25,
             bio: "hi",
             photos: ["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"],
             distance_km: 5
           }
         ]
       }}
    end

    def dating_swipe(attrs) do
      send(:dating_test, {:swipe, attrs})
      Application.get_env(:api_gateway, :test_dating_swipe, {:ok, %{matched: false}})
    end

    def dating_likes(attrs) do
      send(:dating_test, {:likes, attrs})
      {:ok, %{cards: [], next_cursor: nil}}
    end

    def dating_matches(_attrs), do: {:ok, %{matches: [], next_cursor: nil}}

    def dating_unmatch(attrs) do
      send(:dating_test, {:unmatch, attrs})
      {:ok, %{unmatched: true, peer_user_id: "22222222-2222-2222-2222-222222222222"}}
    end

    def dating_unmatch_pair(attrs) do
      send(:dating_test, {:unmatch_pair, attrs})
      {:ok, %{unmatched: true, match_id: "99999999-9999-4999-8999-999999999999"}}
    end

    def dating_attach_conversation(attrs) do
      send(:dating_test, {:attach, attrs})
      {:ok, %{attached: true}}
    end

    # Block-controller path pieces (unused stubs for its enrich).
    def get_public_profile(%{"user_id" => user_id}),
      do: {:ok, %{user_id: user_id, display_name: "X", avatar_media_id: nil}}
  end

  defmodule MediaStub do
    def get_download_url(%{"media_id" => media_id}) do
      {:ok, %{download_url: "https://cdn.test/signed/" <> media_id}}
    end
  end

  defmodule ConversationStub do
    def either_blocked?(_attrs), do: {:ok, %{blocked: false}}

    def create_conversation(attrs) do
      send(:dating_test, {:conversation, attrs})
      {:ok, %{conversation_id: "conv-dating-1", type: "direct", created: false}}
    end

    def block_user(attrs) do
      send(:dating_test, {:block, attrs})
      {:ok, %{blocked: true}}
    end
  end

  defmodule LimiterOk do
    def check_rate(_attrs), do: :ok
  end

  setup do
    Process.register(self(), :dating_test)

    keys = [
      auth_client_adapter: AuthStub,
      user_client_adapter: UserStub,
      conversation_client_adapter: ConversationStub,
      media_client_adapter: MediaStub,
      rate_limiter_adapter: LimiterOk
    ]

    previous = for {key, _} <- keys, into: %{}, do: {key, Application.get_env(:shared_infra, key)}
    for {key, value} <- keys, do: Application.put_env(:shared_infra, key, value)

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:shared_infra, key, value),
          else: Application.delete_env(:shared_infra, key)
      end

      for key <- [:test_dating_update, :test_dating_swipe],
          do: Application.delete_env(:api_gateway, key)
    end)
  end

  defp authed(method, path, params \\ %{}) do
    method
    |> conn(path, params)
    |> put_req_header("authorization", "Bearer token")
  end

  test "PATCH profile rides identity+tenant and broadcasts dating_profile_changed; errors map" do
    ApiGatewayWeb.Endpoint.subscribe("user:" <> @me)
    params = %{"enabled" => true, "dob" => "1999-01-01", "user_id" => "attacker"}

    conn =
      authed(:patch, "/api/v1/dating/profile", params)
      |> DatingController.update_profile(params)

    assert conn.status == 200
    assert_receive {:update_profile, attrs}
    assert attrs["user_id"] == @me
    assert attrs["app_id"] == @app

    assert_receive %Phoenix.Socket.Broadcast{
      event: "dating_profile_changed",
      payload: %{"type" => "dating_profile_changed"}
    }

    for {error, status, code} <- [
          {{:error, :dating_underage}, 403, "dating.underage"},
          {{:error, :dating_profile_incomplete}, 422, "dating.profile_incomplete"},
          {{:error, :dating_dob_locked}, 403, "dating.dob_locked"},
          {{:error, :dating_photo_not_owned}, 422, "dating.photo_not_owned"}
        ] do
      Application.put_env(:api_gateway, :test_dating_update, error)

      conn =
        authed(:patch, "/api/v1/dating/profile", params)
        |> DatingController.update_profile(params)

      assert conn.status == status
      assert %{"error" => %{"code" => ^code}} = Jason.decode!(conn.resp_body)
    end
  end

  test "DECK: photo media ids become PRESIGNED urls; card carries no coordinates" do
    conn = authed(:get, "/api/v1/dating/deck") |> DatingController.deck(%{})
    assert conn.status == 200
    %{"cards" => [card]} = Jason.decode!(conn.resp_body)

    assert card["photos"] == ["https://cdn.test/signed/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"]
    assert card["distance_km"] == 5
    refute Map.has_key?(card, "latitude")
    refute Map.has_key?(card, "longitude")
  end

  test "SWIPE like (no match): dating_like_received to the target, payload locked to the TYPE alone" do
    ApiGatewayWeb.Endpoint.subscribe("user:" <> @peer)
    params = %{"target_id" => @peer, "action" => "like"}

    conn = authed(:post, "/api/v1/dating/swipes", params) |> DatingController.swipe(params)
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"matched" => false}

    assert_receive %Phoenix.Socket.Broadcast{
      event: "dating_like_received",
      payload: payload
    }

    # NO ids, no count, nothing but the type — the target fetches their likes list themselves.
    assert payload == %{"type" => "dating_like_received"}

    # A PASS broadcasts NOTHING (the liker is never notified of anything about passes).
    pass = %{"target_id" => @peer, "action" => "pass"}
    conn = authed(:post, "/api/v1/dating/swipes", pass) |> DatingController.swipe(pass)
    assert conn.status == 200
    refute_receive %Phoenix.Socket.Broadcast{}, 50
  end

  test "SWIPE match: conversation created through THE direct path, attached, both notified (locked)" do
    Application.put_env(
      :api_gateway,
      :test_dating_swipe,
      {:ok, %{matched: true, match_id: @match, conversation_id: nil}}
    )

    ApiGatewayWeb.Endpoint.subscribe("user:" <> @me)
    ApiGatewayWeb.Endpoint.subscribe("user:" <> @peer)

    params = %{"target_id" => @peer, "action" => "like"}
    conn = authed(:post, "/api/v1/dating/swipes", params) |> DatingController.swipe(params)
    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "matched" => true,
             "match_id" => @match,
             "conversation_id" => "conv-dating-1"
           }

    # The ONE direct find-or-create path (nearby precedent), then the attach.
    assert_receive {:conversation, conversation_attrs}
    assert conversation_attrs["type"] == "direct"
    assert conversation_attrs["created_by"] == @me
    assert conversation_attrs["participant_user_ids"] == [@peer]

    assert_receive {:attach, %{"match_id" => @match, "conversation_id" => "conv-dating-1"}}

    # BOTH sides hear dating_matched, each naming the OTHER as user_id.
    expected_me = %{
      "type" => "dating_matched",
      "match_id" => @match,
      "user_id" => @peer,
      "conversation_id" => "conv-dating-1"
    }

    expected_peer = %{expected_me | "user_id" => @me}

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "user:" <> @me,
      event: "dating_matched",
      payload: ^expected_me
    }

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "user:" <> @peer,
      event: "dating_matched",
      payload: ^expected_peer
    }
  end

  test "SWIPE errors: self 422, matched-pass 409" do
    for {error, status, code} <- [
          {{:error, :dating_self_swipe}, 422, "dating.self_swipe"},
          {{:error, :dating_matched}, 409, "dating.matched"}
        ] do
      Application.put_env(:api_gateway, :test_dating_swipe, error)
      params = %{"target_id" => @peer, "action" => "like"}
      conn = authed(:post, "/api/v1/dating/swipes", params) |> DatingController.swipe(params)
      assert conn.status == status
      assert %{"error" => %{"code" => ^code}} = Jason.decode!(conn.resp_body)
    end
  end

  test "UNMATCH broadcasts dating_unmatched to BOTH (payload locked); response is plain" do
    ApiGatewayWeb.Endpoint.subscribe("user:" <> @me)
    ApiGatewayWeb.Endpoint.subscribe("user:" <> @peer)

    params = %{"match_id" => @match}

    conn =
      authed(:delete, "/api/v1/dating/matches/#{@match}", params)
      |> DatingController.unmatch(params)

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"unmatched" => true}

    expected = %{"type" => "dating_unmatched", "match_id" => @match}

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "user:" <> @me,
      event: "dating_unmatched",
      payload: ^expected
    }

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "user:" <> @peer,
      event: "dating_unmatched",
      payload: ^expected
    }
  end

  test "BLOCK HOOK: blocking auto-unmatches the pair and notifies both" do
    ApiGatewayWeb.Endpoint.subscribe("user:" <> @me)
    ApiGatewayWeb.Endpoint.subscribe("user:" <> @peer)

    params = %{"user_id" => @peer}

    conn =
      authed(:post, "/api/v1/blocks", params)
      |> ApiGatewayWeb.BlockController.create(params)

    assert conn.status == 204
    assert_receive {:block, _}
    assert_receive {:unmatch_pair, attrs}
    assert attrs["user_id"] == @me
    assert attrs["peer_user_id"] == @peer
    assert attrs["app_id"] == @app

    expected = %{"type" => "dating_unmatched", "match_id" => @match}

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "user:" <> @me,
      event: "dating_unmatched",
      payload: ^expected
    }

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "user:" <> @peer,
      event: "dating_unmatched",
      payload: ^expected
    }
  end
end
