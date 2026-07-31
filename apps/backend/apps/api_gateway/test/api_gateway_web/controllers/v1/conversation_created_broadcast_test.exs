defmodule ApiGatewayWeb.V1.ConversationCreatedBroadcastTest do
  @moduledoc """
  Creating a conversation fans `conversation_created` (the inbox row) onto each NON-creator participant's
  user:<id> topic — only on a genuine insert, never on an idempotent direct. Stubs the auth + conversation
  clients, subscribes to the endpoint PubSub, and calls the controller directly (bypassing V1Auth via assigns).
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.ConversationBroadcast
  alias ApiGatewayWeb.V1.ConversationController

  @app "44444444-4444-4444-8444-444444444444"
  @creator "u-creator"
  @bob "u-bob"
  @carol "u-carol"

  defmodule AuthStub do
    @moduledoc false
    def resolve_external_user(%{"external_id" => ext}) do
      # ext-bob → u-bob, ext-carol → u-carol, ext-creator → u-creator.
      {:ok, %{user_id: "u-" <> String.replace_prefix(ext, "ext-", "")}}
    end
  end

  defmodule ConvStub do
    @moduledoc false
    # Shape copied from conversation_service conversation_response/2 + create_conversation_in_db's
    # `Map.put(response, :created, …)`: `created` is a MAP FIELD (the real service produces exactly this).
    # Echoes the resolved participants + created_by (what the fan-out reads); the per-test toggle drives
    # the idempotent-direct path. The `round_trip/1` tests below additionally push this through the real
    # HTTP encode/decode so the shape can't drift from the wire.
    def create_conversation(attrs) do
      {:ok,
       %{
         conversation_id: "conv-new",
         type: attrs["type"],
         title: attrs["title"],
         created_by: attrs["created_by"],
         participant_user_ids: attrs["participant_user_ids"],
         created_at: "2026-07-11T00:00:00Z",
         created: Application.get_env(:api_gateway, :test_conv_created, true)
       }}
    end
  end

  setup do
    prev_auth = Application.get_env(:shared_infra, :auth_client_adapter)
    prev_conv = Application.get_env(:shared_infra, :conversation_client_adapter)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)

    on_exit(fn ->
      restore(:auth_client_adapter, prev_auth)
      restore(:conversation_client_adapter, prev_conv)
      Application.delete_env(:api_gateway, :test_conv_created)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  # An end-user conn (creator = @creator) with the params the controller reads.
  defp create_conn(params) do
    :post
    |> conn("/v1/conversations", params)
    |> assign(:v1_app_id, @app)
    |> assign(:v1_actor, :end_user)
    |> assign(:v1_user_id, @creator)
  end

  defp subscribe(user_id), do: Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{user_id}")

  test "group create → each non-creator participant gets conversation_created (inbox row); creator does not" do
    subscribe(@bob)
    subscribe(@carol)
    subscribe(@creator)

    conn =
      ConversationController.create(create_conn(%{}), %{
        "type" => "group",
        "title" => "Team",
        "participants" => ["ext-bob", "ext-carol"]
      })

    assert conn.status == 201

    assert_receive %Phoenix.Socket.Broadcast{event: "conversation_created", payload: bob_row},
                   1000

    assert_receive %Phoenix.Socket.Broadcast{event: "conversation_created", payload: carol_row},
                   1000

    # The inbox-row shape for a brand-new conversation.
    assert bob_row == %{
             conversation_id: "conv-new",
             type: "group",
             title: "Team",
             last_message_preview: nil,
             last_message_kind: nil,
             unread_count: 0,
             updated_at: "2026-07-11T00:00:00Z"
           }

    assert carol_row.conversation_id == "conv-new"
    # The creator is NEVER notified (they got the conversation in the create response).
    refute_receive %Phoenix.Socket.Broadcast{event: "conversation_created"}, 200
  end

  test "genuinely new direct create → the other participant is notified, the creator is not" do
    subscribe(@bob)
    subscribe(@creator)

    conn =
      ConversationController.create(create_conn(%{}), %{
        "type" => "direct",
        "participants" => ["ext-bob"]
      })

    assert conn.status == 201
    assert_receive %Phoenix.Socket.Broadcast{event: "conversation_created", payload: row}, 1000
    assert row.conversation_id == "conv-new"
    refute_receive %Phoenix.Socket.Broadcast{event: "conversation_created"}, 200
  end

  test "idempotent direct that returns an EXISTING conversation → NO broadcast" do
    Application.put_env(:api_gateway, :test_conv_created, false)
    subscribe(@bob)
    subscribe(@creator)

    conn =
      ConversationController.create(create_conn(%{}), %{
        "type" => "direct",
        "participants" => ["ext-bob"]
      })

    # The create still succeeds (returns the existing thread) — just no live event.
    assert conn.status == 201
    refute_receive %Phoenix.Socket.Broadcast{event: "conversation_created"}, 300
  end

  test "the internal :created flag is stripped from the client response" do
    conn =
      ConversationController.create(create_conn(%{}), %{
        "type" => "group",
        "title" => "Team",
        "participants" => ["ext-bob"]
      })

    body = Jason.decode!(conn.resp_body)
    refute Map.has_key?(body, "created")
    assert body["conversation_id"] == "conv-new"
  end

  test "a broadcast failure never affects the create path (fire-and-forget + rescue)" do
    # A malformed participant would crash `\"user:\" <> id` inside the task — broadcast_created still returns
    # :ok synchronously (it only spawns the rescued task), so a create can never be turned into an error.
    assert ConversationBroadcast.broadcast_created(%{
             created: true,
             created_by: @creator,
             participant_user_ids: [123],
             conversation_id: "c",
             type: "group",
             created_at: "t"
           }) == :ok
  end

  # ---- HTTP round-trip: prove `created` (a MAP FIELD, per conversation_response/2 + create_conversation_in_db's
  # Map.put) survives the real encode_result → JSON → decode_result path prod uses (ConversationClientHttp),
  # and that broadcast_created then fires. This is the guard the earlier stub couldn't be: it drives the REAL
  # wire shape, not a hand-made one.
  defp round_trip(resp) do
    {:ok, decoded} =
      {:ok, resp}
      |> SharedInfra.InternalApi.encode_result()
      |> Jason.encode!()
      |> Jason.decode!()
      |> SharedInfra.InternalApi.decode_result()

    decoded
  end

  # The exact shape create_conversation returns: conversation_response/2 fields + created (map field) +
  # participant_user_ids = INTERNAL uuids.
  defp service_response(created?) do
    %{
      conversation_id: "conv-new",
      tenant_id: nil,
      type: "group",
      title: "Team",
      created_by: @creator,
      participant_user_ids: [@creator, @bob, @carol],
      created_at: "2026-07-11T00:00:00Z",
      created: created?
    }
  end

  test "created survives the HTTP round-trip → broadcast_created fires to non-creator participants" do
    decoded = round_trip(service_response(true))
    # The flag genuinely crossed the wire as a map field.
    assert decoded.created == true

    subscribe(@bob)
    subscribe(@carol)
    subscribe(@creator)
    ConversationBroadcast.broadcast_created(decoded)

    assert_receive %Phoenix.Socket.Broadcast{event: "conversation_created", payload: row}, 1000
    assert row.conversation_id == "conv-new"
    assert row.unread_count == 0
    assert_receive %Phoenix.Socket.Broadcast{event: "conversation_created"}, 1000
    refute_receive %Phoenix.Socket.Broadcast{event: "conversation_created"}, 200
  end

  test "created:false survives the round-trip → NO broadcast (idempotent direct)" do
    decoded = round_trip(service_response(false))
    assert decoded.created == false

    subscribe(@bob)
    ConversationBroadcast.broadcast_created(decoded)
    refute_receive %Phoenix.Socket.Broadcast{event: "conversation_created"}, 300
  end
end
