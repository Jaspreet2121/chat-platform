defmodule ApiGatewayWeb.SharingEndpointTest do
  @moduledoc """
  PATCH /api/v1/conversations/:id/settings {sharing_disabled} — the gateway half of 120.

  Mirrors the wallpaper endpoint's contract exactly, and pins the four things the Android client
  consumes verbatim:

    * the 403 (conversation.not_admin) for a group member who is not owner/admin, and the 404
      COLLAPSE for unknown / non-member / cross-tenant;
    * the 422 (conversation.sharing_invalid) for a non-boolean;
    * the SYSTEM MESSAGE — {kind: "sharing", state: "on"|"off", user}. Load-bearing twice: the
      user-visible receipt, and the ONLY path by which a closed chat learns of the change (a closed
      chat has not joined the conversation topic that carries the frame);
    * the FRAME — settings_updated on the conversation topic carrying ONLY the key that changed, so
      a sharing PATCH never mentions wallpaper and a wallpaper PATCH never mentions sharing.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.ConversationController

  @conversation "11111111-1111-4111-8111-111111111111"
  @actor "22222222-2222-4222-8222-222222222222"
  @peer "33333333-3333-4333-8333-333333333333"

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
    def set_sharing_disabled(attrs) do
      send(Application.get_env(:api_gateway, :sharing_test_pid), {:store_set, attrs})

      case Application.get_env(:api_gateway, :sharing_store_result) do
        nil ->
          {:ok,
           %{
             conversation_id: attrs["conversation_id"],
             sharing_disabled: attrs["sharing_disabled"]
           }}

        result ->
          result
      end
    end

    def set_wallpaper(attrs) do
      send(Application.get_env(:api_gateway, :sharing_test_pid), {:store_wallpaper, attrs})
      {:ok, %{conversation_id: attrs["conversation_id"], wallpaper: attrs["wallpaper"]}}
    end

    def get_conversation(_attrs), do: {:ok, %{participants: []}}
  end

  defmodule MsgStub do
    @moduledoc false
    def create_message(attrs) do
      send(Application.get_env(:api_gateway, :sharing_test_pid), {:system_message, attrs})
      {:ok, Map.put(attrs, "message_id", "sys_1")}
    end
  end

  setup do
    keys = [
      {:shared_infra, :auth_client_adapter},
      {:shared_infra, :conversation_client_adapter},
      {:shared_infra, :message_client_adapter},
      {:api_gateway, :sharing_test_pid},
      {:api_gateway, :sharing_store_result}
    ]

    prev = for {app, key} <- keys, into: %{}, do: {{app, key}, Application.get_env(app, key)}

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)
    Application.put_env(:api_gateway, :sharing_test_pid, self())
    Application.delete_env(:api_gateway, :sharing_store_result)

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

  test "ON: persists via the store, emits ONE system message, ONE conversation-topic frame" do
    conn = patch(%{"sharing_disabled" => true})

    assert conn.status == 200

    assert body_of(conn) == %{
             "conversation_id" => @conversation,
             "sharing_disabled" => true
           }

    # (1) the store received the caller's SESSION identity, never payload identity
    assert_receive {:store_set, attrs}
    assert attrs["actor_user_id"] == @actor
    assert attrs["sharing_disabled"] == true

    # (2) exactly ONE system message — the receipt, and the propagation path for CLOSED chats
    assert_receive {:system_message, msg}
    assert msg["message_type"] == "system"
    assert msg["sender_user_id"] == @actor
    assert msg["metadata"] |> Map.keys() |> Enum.sort() == ["kind", "state", "user"]
    assert msg["metadata"]["kind"] == "sharing"
    assert msg["metadata"]["state"] == "on"
    assert msg["metadata"]["user"] == @actor
    # No body — every client renders the sentence locally.
    refute Map.has_key?(msg, "body")
    refute_receive {:system_message, _}, 100

    # (3) the live hint: ONE settings_updated on the CONVERSATION topic, key-set pinned
    assert_receive %Phoenix.Socket.Broadcast{
                     topic: "conversation:" <> _,
                     event: "settings_updated",
                     payload: frame
                   },
                   1000

    assert frame |> Map.keys() |> Enum.sort() == [:conversation_id, :sharing_disabled]
    assert frame.sharing_disabled == true

    refute_receive %Phoenix.Socket.Broadcast{topic: "user:" <> _, event: "settings_updated"}, 150
  end

  test "OFF: false is carried end-to-end — echo, system message and frame all say so" do
    conn = patch(%{"sharing_disabled" => false})

    assert conn.status == 200
    assert body_of(conn)["sharing_disabled"] == false

    assert_receive {:store_set, %{"sharing_disabled" => false}}

    assert_receive {:system_message, msg}

    assert msg["metadata"]["state"] == "off",
           "turning sharing OFF produced no system message saying so — the other side is never " <>
             "told the restriction was lifted"

    assert_receive %Phoenix.Socket.Broadcast{event: "settings_updated", payload: frame}, 1000

    assert frame.sharing_disabled == false,
           "false was dropped from the frame — a falsy value must survive the wire, or the open " <>
             "chat keeps showing the restriction"
  end

  # --- the frame carries ONLY what changed ---------------------------------------------------------

  test "a WALLPAPER patch never mentions sharing_disabled, and vice versa" do
    patch(%{"wallpaper" => %{"kind" => "solid", "color" => "#101418"}})

    assert_receive %Phoenix.Socket.Broadcast{event: "settings_updated", payload: wallpaper_frame},
                   1000

    assert wallpaper_frame |> Map.keys() |> Enum.sort() == [:conversation_id, :wallpaper],
           "a wallpaper change announced sharing_disabled — a client would read the key as an " <>
             "authoritative value and flip a setting nobody touched"

    patch(%{"sharing_disabled" => true})

    assert_receive %Phoenix.Socket.Broadcast{event: "settings_updated", payload: sharing_frame},
                   1000

    assert sharing_frame |> Map.keys() |> Enum.sort() == [:conversation_id, :sharing_disabled]
  end

  test "BOTH keys in one body patch both, each with its own system message" do
    conn = patch(%{"sharing_disabled" => true, "wallpaper" => nil})

    assert conn.status == 200
    assert body_of(conn)["sharing_disabled"] == true
    assert Map.has_key?(body_of(conn), "wallpaper")

    kinds =
      for _ <- 1..2 do
        assert_receive {:system_message, msg}
        msg["metadata"]["kind"]
      end

    assert Enum.sort(kinds) == ["sharing", "wallpaper"]

    assert_receive %Phoenix.Socket.Broadcast{event: "settings_updated", payload: frame}, 1000

    assert frame |> Map.keys() |> Enum.sort() == [
             :conversation_id,
             :sharing_disabled,
             :wallpaper
           ]
  end

  test "a body with NEITHER key is a 400 — nothing to patch, nothing emitted" do
    conn = patch(%{})

    assert conn.status == 400
    refute_receive {:system_message, _}, 100
    refute_receive %Phoenix.Socket.Broadcast{event: "settings_updated"}, 100
  end

  # --- the error contract --------------------------------------------------------------------------

  test "a group MEMBER who is not owner/admin → 403 conversation.not_admin (the PUT's own code)" do
    Application.put_env(:api_gateway, :sharing_store_result, {:error, :participant_forbidden})

    conn = patch(%{"sharing_disabled" => true})

    assert conn.status == 403
    assert body_of(conn)["error"]["code"] == "conversation.not_admin"

    refute_receive {:system_message, _}, 100
    refute_receive %Phoenix.Socket.Broadcast{event: "settings_updated"}, 100
  end

  test "NON-MEMBER → 404, byte-identical to unknown + cross-tenant (no existence reveal)" do
    bodies =
      for atom <- [:participant_not_found, :conversation_not_found, :conversation_forbidden] do
        Application.put_env(:api_gateway, :sharing_store_result, {:error, atom})
        conn = patch(%{"sharing_disabled" => true})
        assert conn.status == 404
        {conn.status, update_in(body_of(conn), ["error", "correlation_id"], fn _ -> "X" end)}
      end

    assert [_] = Enum.uniq(bodies),
           "the three refusal causes are distinguishable on the wire: #{inspect(Enum.uniq(bodies))}"

    assert {404, %{"error" => %{"code" => "conversation.not_found"}}} = hd(bodies)
  end

  test "a NON-BOOLEAN → 422 conversation.sharing_invalid, nothing emitted" do
    Application.put_env(:api_gateway, :sharing_store_result, {:error, :sharing_invalid})

    conn = patch(%{"sharing_disabled" => "true"})

    assert conn.status == 422
    assert body_of(conn)["error"]["code"] == "conversation.sharing_invalid"

    refute_receive {:system_message, _}, 100
    refute_receive %Phoenix.Socket.Broadcast{event: "settings_updated"}, 100
  end
end
