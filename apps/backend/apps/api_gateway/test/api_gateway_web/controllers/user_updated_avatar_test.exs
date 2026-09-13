defmodule ApiGatewayWeb.UserUpdatedAvatarTest do
  @moduledoc """
  `user_updated` on an avatar change — the live replacement for "B sees A's old picture until B's
  next card fetch".

  Android keys its avatar cache on `avatar_media_id` and reads that id off the peer's card, so the
  four things pinned here are the whole contract: the event carries the NEW id (or nil on a clear),
  it reaches everyone who shares a conversation with the actor, it never reaches the actor, and it
  is emitted only AFTER the store has committed — an event describing a write that has not landed
  sends every recipient to fetch the value it just told them about and get the old one back.

  The commit-ordering assertion works by observing the store from INSIDE the fan-out: the recipient
  lookup runs during emission, so what the store holds at that moment is what the event was emitted
  against.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.UserController

  @actor "11111111-1111-4111-8111-111111111111"
  @peer "22222222-2222-4222-8222-222222222222"
  @stranger "33333333-3333-4333-8333-333333333333"
  @app "44444444-4444-4444-8444-444444444444"

  @old_avatar "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @new_avatar "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer actor"}),
      do:
        {:ok,
         %{
           user_id: "11111111-1111-4111-8111-111111111111",
           app_id: "44444444-4444-4444-8444-444444444444",
           email: nil
         }}

    def current_session(_), do: {:error, :session_invalid}
  end

  # The profile store, as a tiny committed-state machine. `update_current_profile` is the COMMIT.
  defmodule UserStub do
    @moduledoc false
    def start_link, do: Agent.start_link(fn -> %{avatar: nil, bio: nil} end, name: __MODULE__)
    def committed, do: Agent.get(__MODULE__, & &1)

    def update_current_profile(attrs) do
      avatar =
        case Map.fetch(attrs, "avatar_media_id") do
          {:ok, ""} -> nil
          {:ok, value} -> value
          :error -> Agent.get(__MODULE__, & &1.avatar)
        end

      bio = Map.get(attrs, "bio") || Agent.get(__MODULE__, & &1.bio)
      Agent.update(__MODULE__, fn _ -> %{avatar: avatar, bio: bio} end)

      {:ok,
       %{
         user_id: attrs["user_id"],
         avatar_media_id: avatar,
         bio: bio,
         app_id: "44444444-4444-4444-8444-444444444444"
       }}
    end
  end

  defmodule ConvStub do
    @moduledoc false
    # Called DURING the fan-out — so what the store holds here is the state the event was emitted
    # against. That is what makes the after-commit ordering assertable rather than assumed.
    def peers_of(%{"user_id" => _actor}) do
      send(
        Application.get_env(:api_gateway, :user_updated_test_pid),
        {:peers_of_called, ApiGatewayWeb.UserUpdatedAvatarTest.UserStub.committed()}
      )

      # Steerable, so the three lookup outcomes — a real set, an EMPTY set, and a FAILURE — can each
      # be produced on demand. They must log differently; that is the whole point of the split.
      case Application.get_env(:api_gateway, :peers_of_result) do
        nil ->
          {:ok,
           %{
             user_ids: [
               "22222222-2222-4222-8222-222222222222",
               # The actor comes back in the peer set too (a self-DM, or just a sloppy query) — the
               # emitter must drop it rather than echo the change to the device that made it.
               "11111111-1111-4111-8111-111111111111"
             ]
           }}

        result ->
          result
      end
    end
  end

  defmodule MediaStub do
    @moduledoc false
    def get_asset(%{"media_id" => media_id}),
      do:
        {:ok,
         %{
           media_id: media_id,
           owner_user_id: "11111111-1111-4111-8111-111111111111",
           purpose: "user_avatar",
           status: "ready"
         }}

    def get_download_url(_attrs), do: {:error, :media_unavailable}
  end

  setup do
    keys = [
      {:shared_infra, :auth_client_adapter},
      {:shared_infra, :user_client_adapter},
      {:shared_infra, :conversation_client_adapter},
      {:shared_infra, :media_client_adapter},
      {:api_gateway, :user_updated_test_pid},
      {:api_gateway, :peers_of_result},
      {:user_service, :user_profile_persistence}
    ]

    prev = for {app, key} <- keys, into: %{}, do: {{app, key}, Application.get_env(app, key)}

    start_supervised!(%{id: UserStub, start: {UserStub, :start_link, []}})

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)
    Application.put_env(:api_gateway, :user_updated_test_pid, self())
    Application.delete_env(:api_gateway, :peers_of_result)
    Application.put_env(:user_service, :user_profile_persistence, true)

    on_exit(fn ->
      for {{app, key}, value} <- prev do
        if value == nil,
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end
    end)

    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@peer}")
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@actor}")
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@stranger}")

    :ok
  end

  defp patch_me(body) do
    :patch
    |> conn("/api/v1/users/me", %{})
    |> put_req_header("authorization", "Bearer actor")
    |> UserController.update_me(body)
  end

  # --- the event ------------------------------------------------------------------------------------

  test "setting an avatar emits user_updated to the PEER, key-set pinned" do
    conn = patch_me(%{"avatar_media_id" => @new_avatar})
    assert conn.status == 200

    assert_receive %Phoenix.Socket.Broadcast{
                     topic: "user:" <> _,
                     event: "user_updated",
                     payload: payload
                   },
                   1000

    assert payload |> Map.keys() |> Enum.sort() == [:avatar_media_id, :user_id],
           "the payload is a wire contract Android reads verbatim"

    assert payload.user_id == @actor
    assert payload.avatar_media_id == @new_avatar
  end

  test "CLEARING the avatar emits nil — a removed photo must disappear, not linger" do
    patch_me(%{"avatar_media_id" => @new_avatar})
    assert_receive %Phoenix.Socket.Broadcast{event: "user_updated"}, 1000

    conn = patch_me(%{"avatar_media_id" => ""})
    assert conn.status == 200

    assert_receive %Phoenix.Socket.Broadcast{event: "user_updated", payload: payload}, 1000

    assert payload.avatar_media_id == nil,
           "a cleared photo emitted no id change — every peer keeps drawing the old one forever"
  end

  test "NEVER to the actor — their own devices already have the response they asked for" do
    patch_me(%{"avatar_media_id" => @new_avatar})

    assert_receive %Phoenix.Socket.Broadcast{topic: "user:" <> got, event: "user_updated"}, 1000
    assert got == @peer

    actor_topic = "user:" <> @actor
    refute_receive %Phoenix.Socket.Broadcast{topic: ^actor_topic, event: "user_updated"}, 200
  end

  test "only the peer set — a stranger's topic is silent" do
    patch_me(%{"avatar_media_id" => @new_avatar})
    assert_receive %Phoenix.Socket.Broadcast{event: "user_updated"}, 1000

    stranger_topic = "user:" <> @stranger
    refute_receive %Phoenix.Socket.Broadcast{topic: ^stranger_topic, event: "user_updated"}, 200
  end

  # --- ordering -------------------------------------------------------------------------------------

  test "emitted AFTER the commit: the store already holds the new avatar when the fan-out runs" do
    patch_me(%{"avatar_media_id" => @new_avatar})

    assert_receive {:peers_of_called, committed}, 1000

    assert committed.avatar == @new_avatar,
           "the fan-out ran against #{inspect(committed.avatar)} — the event was emitted BEFORE the " <>
             "write landed, so every recipient re-fetches and gets the value it was just told replaced"
  end

  # --- scope ----------------------------------------------------------------------------------------

  test "a BIO-only change emits nothing — not an avatar change" do
    conn = patch_me(%{"bio" => "still me"})
    assert conn.status == 200

    refute_receive %Phoenix.Socket.Broadcast{event: "user_updated"}, 200
    refute_receive {:peers_of_called, _}, 200
  end

  test "a DISPLAY-NAME-only change emits nothing either" do
    conn = patch_me(%{"display_name" => "A. Person"})
    assert conn.status == 200

    refute_receive %Phoenix.Socket.Broadcast{event: "user_updated"}, 200
  end

  # --- every outcome names itself -------------------------------------------------------------------
  #
  # These four lines are the difference between "the event never reached the phone" being a grep and
  # being an inspection. Before them, success, an empty recipient set and a FAILED lookup all logged
  # nothing — the same silent-success class FcmSender had before 60b84d2.

  describe "logging" do
    test "EMITTED: names the actor and how many recipients got it" do
      log = capture_log([level: :info], fn -> patch_me(%{"avatar_media_id" => @new_avatar}) end)

      # The stub returns peer + actor; the actor is dropped, so exactly ONE recipient.
      assert log =~ "user_updated emitted user=#{@actor} recipients=1",
             "a successful emit logged nothing — 'did it fire?' goes back to watching a socket"
    end

    test "NO_PEERS: an empty set says so, at info — not silence" do
      Application.put_env(:api_gateway, :peers_of_result, {:ok, %{user_ids: []}})

      log = capture_log([level: :info], fn -> patch_me(%{"avatar_media_id" => @new_avatar}) end)

      assert log =~ "user_updated skipped user=#{@actor} reason=no_peers"
      refute log =~ "user_updated emitted"
      refute log =~ "user_updated failed"
    end

    test "NO_PEERS also when the only 'peer' is the actor themselves" do
      Application.put_env(
        :api_gateway,
        :peers_of_result,
        {:ok, %{user_ids: ["11111111-1111-4111-8111-111111111111"]}}
      )

      log = capture_log([level: :info], fn -> patch_me(%{"avatar_media_id" => @new_avatar}) end)
      assert log =~ "reason=no_peers"
    end

    test "FAILED: a peer-lookup error is a WARNING with the reason — never no_peers" do
      Application.put_env(:api_gateway, :peers_of_result, {:error, :conversation_unavailable})

      log = capture_log([level: :info], fn -> patch_me(%{"avatar_media_id" => @new_avatar}) end)

      assert log =~ "[warning] user_updated failed user=#{@actor}: :conversation_unavailable",
             "a conversation-service outage logged as a user with no conversations — the one " <>
               "line that would have said 'the dependency is down' reads as 'nothing to do'"

      refute log =~ "reason=no_peers"
      refute_receive %Phoenix.Socket.Broadcast{event: "user_updated"}, 100
    end

    test "FAILED: a malformed reply (no user_ids list) is an error too, not an empty set" do
      Application.put_env(:api_gateway, :peers_of_result, {:ok, %{something_else: 1}})

      log = capture_log([level: :info], fn -> patch_me(%{"avatar_media_id" => @new_avatar}) end)

      assert log =~ "user_updated failed user=#{@actor}"
      refute log =~ "reason=no_peers"
    end

    test "NO_CHANGE: a PATCH without the avatar key says why nothing was emitted" do
      log = capture_log([level: :info], fn -> patch_me(%{"bio" => "still me"}) end)

      assert log =~ "user_updated skipped user=#{@actor} reason=no_change",
             "a PATCH that reached the server without avatar_media_id left no trace — a client " <>
               "sending a different key is invisible"

      refute_receive {:peers_of_called, _}, 100
    end
  end
end
