defmodule ApiGatewayWeb.ConversationLeaveTest do
  @moduledoc """
  The first-party leave endpoint + the DELETE self-target compatibility shim. Session-authed; Auth +
  ConversationClient stubbed, PubSub subscribed. Proves the contract: POST /leave → 200 (with
  new_owner_user_id passed through when ownership transferred) + the :participant frame with the LEAVER's
  final `removed: true` frame; the shipped-Android DELETE /:id/participants/{own_id} routes to the SAME
  leave path (NOT the moderation call); a non-self DELETE still hits moderation; direct chat → 400
  conversation.not_a_group; no session → 401. The SQL (transfer, archive-if-last, left_reason) is proven
  in ConversationService.LeaveConversationTest.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.ConversationController

  @me "11111111-1111-4111-8111-111111111111"
  @peer "44444444-4444-4444-8444-444444444444"
  @conv "22222222-2222-4222-8222-222222222222"

  defmodule AuthStub do
    @me "11111111-1111-4111-8111-111111111111"
    def current_session(%{"authorization" => "Bearer me"}), do: {:ok, %{user_id: @me, app_id: "app1"}}
    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConvStub do
    def start_link, do: Agent.start_link(fn -> %{calls: [], mode: :plain} end, name: __MODULE__)
    def set_mode(mode), do: Agent.update(__MODULE__, &Map.put(&1, :mode, mode))
    def calls, do: Agent.get(__MODULE__, & &1.calls)
    defp record(call), do: Agent.update(__MODULE__, &Map.update!(&1, :calls, fn c -> c ++ [call] end))

    def leave_conversation(%{"conversation_id" => c, "user_id" => u}) do
      record({:leave_conversation, u})

      case Agent.get(__MODULE__, & &1.mode) do
        :transfer ->
          {:ok, %{conversation_id: c, left: true, conversation_archived: false, new_owner_user_id: "u-next"}}

        :direct ->
          {:error, :not_a_group}

        _ ->
          {:ok, %{conversation_id: c, left: true, conversation_archived: false}}
      end
    end

    def remove_participant(%{"conversation_id" => c, "user_id" => u}) do
      record({:remove_participant, u})
      {:ok, %{conversation_id: c, user_id: u, removed: true, left_at: "2026-07-30T00:00:00Z"}}
    end

    # Consumed by the :participant broadcast (removed_user_id short-circuits for the leaver).
    def get_conversation(_attrs), do: {:ok, %{participants: [%{user_id: "u-other"}]}}

    def inbox_rows(%{"conversation_id" => c, "user_ids" => uids}) do
      {:ok, %{rows: Enum.map(uids, &%{user_id: &1, conversation_id: c, unread_count: 0})}}
    end
  end

  setup do
    start_supervised!(%{id: ConvStub, start: {ConvStub, :start_link, []}})

    prev = %{
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      conv: Application.get_env(:shared_infra, :conversation_client_adapter),
      persistence: Application.get_env(:conversation_service, :conversation_persistence)
    }

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    # The DELETE action branches on persistence; force the DB-backed path so the shim is exercised.
    Application.put_env(:conversation_service, :conversation_persistence, true)

    on_exit(fn ->
      restore(:shared_infra, :auth_client_adapter, prev.auth)
      restore(:shared_infra, :conversation_client_adapter, prev.conv)
      restore(:conversation_service, :conversation_persistence, prev.persistence)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp authed(method, token \\ "me") do
    method |> conn("/x", %{}) |> put_req_header("authorization", "Bearer #{token}")
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "POST /leave → 200 {left} + the :participant frame with the LEAVER's final removed:true" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@me}")

    conn = ConversationController.leave(authed(:post), %{"conversation_id" => @conv})

    assert conn.status == 200
    assert body(conn) == %{"conversation_id" => @conv, "left" => true, "conversation_archived" => false}

    # The leaver's final frame: removed:true (clears their inbox row without a refetch).
    assert_receive %Phoenix.Socket.Broadcast{
                     event: "conversation_updated",
                     topic: "user:" <> _,
                     payload: %{"removed" => true, "conversation_id" => @conv}
                   },
                   1000
  end

  test "ownership transfer: new_owner_user_id passes through to the response" do
    ConvStub.set_mode(:transfer)

    conn = ConversationController.leave(authed(:post), %{"conversation_id" => @conv})

    assert conn.status == 200
    assert body(conn)["new_owner_user_id"] == "u-next"
  end

  test "COMPATIBILITY SHIM: DELETE self-target routes to leave_conversation, NOT the moderation call" do
    conn =
      ConversationController.remove_participant(authed(:delete), %{
        "conversation_id" => @conv,
        "user_id" => @me
      })

    assert conn.status == 200
    assert body(conn)["left"] == true
    # The moderation client op was never touched; the leave op was.
    assert ConvStub.calls() == [{:leave_conversation, @me}]
  end

  test "a NON-self DELETE still goes through the moderation path untouched" do
    conn =
      ConversationController.remove_participant(authed(:delete), %{
        "conversation_id" => @conv,
        "user_id" => @peer
      })

    assert conn.status == 200
    assert body(conn)["removed"] == true
    assert ConvStub.calls() == [{:remove_participant, @peer}]
  end

  test "leaving a DIRECT chat → 400 conversation.not_a_group" do
    ConvStub.set_mode(:direct)

    conn = ConversationController.leave(authed(:post), %{"conversation_id" => @conv})

    assert conn.status == 400
    assert body(conn)["error"]["code"] == "conversation.not_a_group"
  end

  test "no session → 401 (both the canonical route and the shim)" do
    assert ConversationController.leave(authed(:post, "nobody"), %{"conversation_id" => @conv}).status == 401

    assert ConversationController.remove_participant(authed(:delete, "nobody"), %{
             "conversation_id" => @conv,
             "user_id" => @me
           }).status == 401
  end
end
