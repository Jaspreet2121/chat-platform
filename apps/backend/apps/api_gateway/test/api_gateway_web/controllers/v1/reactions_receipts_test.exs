defmodule ApiGatewayWeb.V1.ReactionsReceiptsTest do
  @moduledoc """
  /v1 reactions + read/delivered receipts. Docker-free: stubs the conversation + message clients and
  subscribes to the endpoint PubSub, so we exercise the actor rules (END-USER only), the membership gate,
  and the LIVE broadcast — asserting the socket path's EXACT frames (reaction_updated / receipt_updated,
  the latter with message_id NESTED under `payload`).
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.V1.MessageController

  @app "44444444-4444-4444-8444-444444444444"
  @user "u-alice"
  @conv "conv-1"
  @msg "msg-1"

  defmodule ConvStub do
    @moduledoc false
    def get_conversation(%{"conversation_id" => "conv-1"}),
      do: {:ok, %{conversation_id: "conv-1", app_id: "44444444-4444-4444-8444-444444444444"}}

    def get_conversation(_), do: {:error, :conversation_not_found}
    def get_conversation_app(%{"conversation_id" => "conv-1"}), do: {:ok, %{conversation_id: "conv-1"}}
    def get_conversation_app(_), do: {:error, :conversation_not_found}
  end

  defmodule MsgStub do
    @moduledoc false
    # Models the ONE-REACTION-PER-USER upsert with a tiny Agent: a user's second emoji REPLACES their first.
    # Aggregate element shape copied from MessageStore: %{emoji, count} (no user_ids).
    def start_link, do: Agent.start_link(fn -> %{} end, name: __MODULE__)
    def reset, do: Agent.update(__MODULE__, fn _ -> %{} end)

    def add_reaction(%{"message_id" => id, "user_id" => user, "emoji" => emoji}) do
      Agent.update(__MODULE__, &Map.put(&1, user, emoji))
      {:ok, %{message_id: id, reactions: aggregate()}}
    end

    def remove_reaction(%{"message_id" => id, "user_id" => user}) do
      Agent.update(__MODULE__, &Map.delete(&1, user))
      {:ok, %{message_id: id, reactions: aggregate()}}
    end

    defp aggregate do
      Agent.get(__MODULE__, & &1)
      |> Enum.frequencies_by(fn {_user, emoji} -> emoji end)
      |> Enum.map(fn {emoji, count} -> %{emoji: emoji, count: count} end)
      |> Enum.sort_by(fn %{count: c, emoji: e} -> {-c, e} end)
    end

    def mark_read(attrs), do: {:ok, Map.put(attrs, "status", "read")}
    def mark_delivered(attrs), do: {:ok, Map.put(attrs, "status", "delivered")}
  end

  setup do
    start_supervised!(%{id: MsgStub, start: {MsgStub, :start_link, []}})
    MsgStub.reset()

    prev_conv = Application.get_env(:shared_infra, :conversation_client_adapter)
    prev_msg = Application.get_env(:shared_infra, :message_client_adapter)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)

    on_exit(fn ->
      restore(:conversation_client_adapter, prev_conv)
      restore(:message_client_adapter, prev_msg)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  defp end_user_conn(method, user_id \\ @user) do
    method
    |> conn("/v1/…", %{})
    |> assign(:v1_app_id, @app)
    |> assign(:v1_actor, :end_user)
    |> assign(:v1_user_id, user_id)
  end

  # An app (secret-key) actor: V1Auth sets NO :v1_user_id.
  defp app_conn(method) do
    method
    |> conn("/v1/…", %{})
    |> assign(:v1_app_id, @app)
    |> assign(:v1_actor, :app)
  end

  defp subscribe_conv, do: Phoenix.PubSub.subscribe(ApiGateway.PubSub, "conversation:#{@conv}")
  defp base, do: %{"id" => @conv, "message_id" => @msg}

  # --- reactions ---------------------------------------------------------------------------------

  test "end-user reacts → 200 with the aggregate, and reaction_updated broadcasts live" do
    subscribe_conv()

    conn = MessageController.set_reaction(end_user_conn(:put), Map.put(base(), "emoji", "👍"))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["message_id"] == @msg
    assert body["reactions"] == [%{"emoji" => "👍", "count" => 1}]

    # The SAME event + payload the socket's reaction:set emits.
    assert_receive %Phoenix.Socket.Broadcast{event: "reaction_updated", payload: payload}, 1000
    assert payload.message_id == @msg
    assert payload.reactions == [%{emoji: "👍", count: 1}]
  end

  test "a second emoji from the SAME user REPLACES the first (one reaction per user)" do
    assert %{status: 200} = MessageController.set_reaction(end_user_conn(:put), Map.put(base(), "emoji", "👍"))

    conn = MessageController.set_reaction(end_user_conn(:put), Map.put(base(), "emoji", "🎉"))

    # Not additive — the aggregate has ONLY the new emoji.
    assert Jason.decode!(conn.resp_body)["reactions"] == [%{"emoji" => "🎉", "count" => 1}]
  end

  test "removing the caller's reaction drops it from the aggregate" do
    MessageController.set_reaction(end_user_conn(:put), Map.put(base(), "emoji", "👍"))
    subscribe_conv()

    conn = MessageController.remove_reaction(end_user_conn(:delete), base())

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["reactions"] == []
    assert_receive %Phoenix.Socket.Broadcast{event: "reaction_updated", payload: %{reactions: []}}, 1000
  end

  test "an APP (secret-key) actor cannot react → 403 v1.end_user_only, nothing broadcasts" do
    subscribe_conv()

    conn = MessageController.set_reaction(app_conn(:put), Map.put(base(), "emoji", "👍"))

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "v1.end_user_only"
    refute_receive %Phoenix.Socket.Broadcast{event: "reaction_updated"}, 300
  end

  test "reacting in a conversation the caller is NOT a member of → 404, nothing broadcasts" do
    subscribe_conv()

    conn =
      MessageController.set_reaction(
        end_user_conn(:put),
        %{"id" => "conv-other", "message_id" => @msg, "emoji" => "👍"}
      )

    assert conn.status == 404
    refute_receive %Phoenix.Socket.Broadcast{event: "reaction_updated"}, 300
  end

  test "an empty emoji → 400" do
    conn = MessageController.set_reaction(end_user_conn(:put), Map.put(base(), "emoji", ""))
    assert conn.status == 400
  end

  # --- receipts ----------------------------------------------------------------------------------

  test "end-user marks read → 200 + receipt_updated, with message_id NESTED under payload (socket shape)" do
    subscribe_conv()

    conn = MessageController.receipt(end_user_conn(:post), Map.put(base(), "type", "read"))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["message_id"] == @msg
    assert body["receipt_type"] == "read"

    assert_receive %Phoenix.Socket.Broadcast{event: "receipt_updated", payload: payload}, 1000
    assert payload.receipt_type == "read"
    assert payload.user_id == @user
    assert payload.event == "message_read"
    # The SDK reads payload.payload.message_id — it MUST stay nested or the wire forks from the socket.
    assert payload.payload["message_id"] == @msg
  end

  test "delivered receipts work the same way" do
    subscribe_conv()

    conn = MessageController.receipt(end_user_conn(:post), Map.put(base(), "type", "delivered"))

    assert conn.status == 200
    assert_receive %Phoenix.Socket.Broadcast{event: "receipt_updated", payload: payload}, 1000
    assert payload.receipt_type == "delivered"
    assert payload.event == "message_delivered"
  end

  test "an APP actor cannot mark read → 403 v1.end_user_only (a server does not read messages)" do
    conn = MessageController.receipt(app_conn(:post), Map.put(base(), "type", "read"))

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "v1.end_user_only"
  end

  test "an invalid receipt type → 422" do
    conn = MessageController.receipt(end_user_conn(:post), Map.put(base(), "type", "seen"))
    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "v1.invalid_receipt_type"
  end

  test "a receipt in a conversation the caller is NOT a member of → 404" do
    conn =
      MessageController.receipt(
        end_user_conn(:post),
        %{"id" => "conv-other", "message_id" => @msg, "type" => "read"}
      )

    assert conn.status == 404
  end
end
