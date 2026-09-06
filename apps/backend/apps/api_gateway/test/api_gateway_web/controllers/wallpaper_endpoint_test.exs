defmodule ApiGatewayWeb.WallpaperEndpointTest do
  @moduledoc """
  PATCH /api/v1/conversations/:id/settings {wallpaper} — the gateway half of 117.

  Pinned here, because the Android slice consumes each verbatim:

    * the 404 COLLAPSE: unknown, non-member and cross-tenant conversations answer with ONE
      byte-identical body (conversation.not_found) — never a 403, never a distinguishable shape;
    * the group rule's 403 (conversation.not_admin) stays the PUT's code;
    * the THREE effects of a successful change, in their live forms: the response echoes the stored
      wallpaper; exactly ONE system message (message_type "system", metadata.kind "wallpaper") rides
      the timeline; and ONE settings_updated frame lands on the CONVERSATION topic — key-set pinned,
      and refuted on user topics (closed chats read the persisted setting on next fetch, by design).
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.ConversationController

  @conversation "11111111-1111-4111-8111-111111111111"
  @actor "22222222-2222-4222-8222-222222222222"
  @peer "33333333-3333-4333-8333-333333333333"

  @wallpaper %{"kind" => "pattern", "id" => "doodle_07", "intensity" => 0.18}

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer actor"}),
      do:
        {:ok,
         %{
           user_id: "22222222-2222-4222-8222-222222222222",
           app_id: "44444444-4444-4444-8444-444444444444"
         }}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConvStub do
    @moduledoc false
    # The store seam: echo success unless :wallpaper_store_result overrides.
    def set_wallpaper(attrs) do
      send(Application.get_env(:api_gateway, :wallpaper_test_pid), {:store_set, attrs})

      case Application.get_env(:api_gateway, :wallpaper_store_result) do
        nil -> {:ok, %{conversation_id: attrs["conversation_id"], wallpaper: attrs["wallpaper"]}}
        result -> result
      end
    end

    # RealtimeFanOut.to_participants is NOT used here, but participants_except reads this if it ever
    # were — a stub that returns nobody keeps any accidental user-topic fan-out visible as a failure.
    def get_conversation(_attrs), do: {:ok, %{participants: []}}
  end

  defmodule MsgStub do
    @moduledoc false
    def create_message(attrs) do
      send(Application.get_env(:api_gateway, :wallpaper_test_pid), {:system_message, attrs})
      {:ok, Map.put(attrs, "message_id", "sys_1")}
    end
  end

  setup do
    keys = [
      {:shared_infra, :auth_client_adapter},
      {:shared_infra, :conversation_client_adapter},
      {:shared_infra, :message_client_adapter},
      {:api_gateway, :wallpaper_test_pid},
      {:api_gateway, :wallpaper_store_result}
    ]

    prev = for {app, key} <- keys, into: %{}, do: {{app, key}, Application.get_env(app, key)}

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)
    Application.put_env(:api_gateway, :wallpaper_test_pid, self())
    Application.delete_env(:api_gateway, :wallpaper_store_result)

    on_exit(fn ->
      for {{app, key}, value} <- prev do
        if value == nil,
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end
    end)

    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "conversation:#{@conversation}")
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@peer}")

    :ok
  end

  defp patch(body, conversation_id \\ @conversation) do
    :patch
    |> conn("/api/v1/conversations/#{conversation_id}/settings", %{})
    |> put_req_header("authorization", "Bearer actor")
    |> ConversationController.patch_settings(Map.put(body, "conversation_id", conversation_id))
  end

  defp body_of(conn), do: Jason.decode!(conn.resp_body)

  # --- the three effects ---------------------------------------------------------------------------

  test "SET: persists via the store, emits ONE system message, ONE conversation-topic frame" do
    conn = patch(%{"wallpaper" => @wallpaper})
    assert conn.status == 200
    assert body_of(conn)["wallpaper"] == @wallpaper

    # (1) the store received the caller's SESSION identity, never payload identity
    assert_receive {:store_set, attrs}
    assert attrs["actor_user_id"] == @actor
    assert attrs["wallpaper"] == @wallpaper

    # (2) exactly ONE system message, the 0b shape: message_type "system" + structured metadata
    assert_receive {:system_message, msg}
    assert msg["message_type"] == "system"
    assert msg["sender_user_id"] == @actor

    assert msg["metadata"] |> Map.keys() |> Enum.sort() == ["kind", "state", "user"]
    assert msg["metadata"]["kind"] == "wallpaper"
    assert msg["metadata"]["state"] == "set"
    refute_receive {:system_message, _}, 100

    # ...and its message_created rides the conversation topic (SecretChatEvents' own broadcast)
    assert_receive %Phoenix.Socket.Broadcast{
                     topic: "conversation:" <> _,
                     event: "message_created"
                   },
                   1000

    # (3) the live hint: ONE settings_updated on the CONVERSATION topic, key-set pinned
    assert_receive %Phoenix.Socket.Broadcast{
                     topic: "conversation:" <> _,
                     event: "settings_updated",
                     payload: frame
                   },
                   1000

    assert frame |> Map.keys() |> Enum.sort() == [:conversation_id, :wallpaper]
    assert frame.wallpaper == @wallpaper

    # NEVER on user topics — a closed chat reads the persisted setting on its next fetch.
    refute_receive %Phoenix.Socket.Broadcast{topic: "user:" <> _, event: "settings_updated"}, 150
  end

  test "CLEAR: null flows through; the system message says cleared" do
    conn = patch(%{"wallpaper" => nil})
    assert conn.status == 200
    assert body_of(conn)["wallpaper"] == nil

    assert_receive {:system_message, msg}
    assert msg["metadata"]["state"] == "cleared"

    assert_receive %Phoenix.Socket.Broadcast{event: "settings_updated", payload: frame}, 1000
    assert frame.wallpaper == nil
  end

  test "a body WITHOUT the wallpaper key is a 400 — nothing to patch, nothing broadcast" do
    conn = patch(%{})
    assert conn.status == 400

    refute_receive {:system_message, _}, 100
    refute_receive %Phoenix.Socket.Broadcast{event: "settings_updated"}, 100
  end

  # --- the error contract --------------------------------------------------------------------------

  test "NON-MEMBER → 404, and byte-identical to unknown + cross-tenant (no existence reveal)" do
    bodies =
      for atom <- [:participant_not_found, :conversation_not_found, :conversation_forbidden] do
        Application.put_env(:api_gateway, :wallpaper_store_result, {:error, atom})
        conn = patch(%{"wallpaper" => @wallpaper})
        assert conn.status == 404
        body = body_of(conn)
        # correlation ids differ per request; the CONTRACT is everything else
        {conn.status, update_in(body, ["error", "correlation_id"], fn _ -> "X" end)}
      end

    assert [_] = Enum.uniq(bodies),
           "the three refusal causes are distinguishable on the wire: #{inspect(Enum.uniq(bodies))}"

    assert {404, %{"error" => %{"code" => "conversation.not_found"}}} = hd(bodies)

    refute_receive {:system_message, _}, 100
    refute_receive %Phoenix.Socket.Broadcast{event: "settings_updated"}, 100
  end

  test "a group MEMBER who is not owner/admin → 403 conversation.not_admin (the PUT's own code)" do
    Application.put_env(:api_gateway, :wallpaper_store_result, {:error, :participant_forbidden})

    conn = patch(%{"wallpaper" => @wallpaper})
    assert conn.status == 403
    assert body_of(conn)["error"]["code"] == "conversation.not_admin"
  end

  test "an invalid wallpaper → 422 conversation.wallpaper_invalid, nothing emitted" do
    Application.put_env(:api_gateway, :wallpaper_store_result, {:error, :wallpaper_invalid})

    conn = patch(%{"wallpaper" => %{"kind" => "photo"}})
    assert conn.status == 422
    assert body_of(conn)["error"]["code"] == "conversation.wallpaper_invalid"

    refute_receive {:system_message, _}, 100
    refute_receive %Phoenix.Socket.Broadcast{event: "settings_updated"}, 100
  end
end
