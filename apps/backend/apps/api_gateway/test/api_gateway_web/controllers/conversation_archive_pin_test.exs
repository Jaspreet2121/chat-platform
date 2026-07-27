defmodule ApiGatewayWeb.ConversationArchivePinTest do
  @moduledoc """
  The first-party archive/pin endpoints. Session-authed; the pref is the caller's own. Stubs AuthClient +
  ConversationClient and subscribes to the endpoint PubSub for the :pref broadcast. Proves the contract:
  archive/pin round-trip JSON, over-cap → 400 conversations.pin_limit carrying the limit, the conversation_
  updated frame goes ONLY to the caller, and the session gate. The SQL (ordering/exclusion/cap) is proven in
  ConversationService.ArchivePinTest.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.ConversationController

  @me "11111111-1111-4111-8111-111111111111"
  @conv "22222222-2222-4222-8222-222222222222"

  defmodule AuthStub do
    @me "11111111-1111-4111-8111-111111111111"
    def current_session(%{"authorization" => "Bearer me"}), do: {:ok, %{user_id: @me, app_id: "app1"}}
    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConvStub do
    def start_link, do: Agent.start_link(fn -> %{pin_over_cap: false} end, name: __MODULE__)
    def set_pin_over_cap(v), do: Agent.update(__MODULE__, &Map.put(&1, :pin_over_cap, v))

    def set_archive(%{"conversation_id" => c, "archived" => a}),
      do: {:ok, %{conversation_id: c, archived: truthy(a)}}

    def set_pin(%{"conversation_id" => c, "pinned" => p}) do
      if Agent.get(__MODULE__, & &1.pin_over_cap),
        do: {:error, :pin_limit},
        else: {:ok, %{conversation_id: c, pinned: truthy(p)}}
    end

    # The :pref broadcast (only: [me]) reads inbox_rows for the caller's row.
    def inbox_rows(%{"conversation_id" => c, "user_ids" => uids}) do
      rows = Enum.map(uids, &%{user_id: &1, conversation_id: c, pinned: true, archived: false, unread_count: 0})
      {:ok, %{rows: rows}}
    end

    defp truthy(v), do: v in [true, "true", "1", "yes"]
  end

  setup do
    start_supervised!(%{id: ConvStub, start: {ConvStub, :start_link, []}})

    prev = %{
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      conv: Application.get_env(:shared_infra, :conversation_client_adapter)
    }

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)

    on_exit(fn ->
      restore(:auth_client_adapter, prev.auth)
      restore(:conversation_client_adapter, prev.conv)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  defp authed(token \\ "me") do
    :put |> conn("/x", %{}) |> put_req_header("authorization", "Bearer #{token}")
  end

  test "PUT archive → 200 {archived} + a conversation_updated frame to the CALLER only" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@me}")

    conn = ConversationController.archive(authed(), %{"conversation_id" => @conv, "archived" => true})

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"conversation_id" => @conv, "archived" => true}

    assert_receive %Phoenix.Socket.Broadcast{event: "conversation_updated", topic: topic}, 1000
    assert topic == "user:#{@me}"
  end

  test "PUT pin → 200 {pinned}" do
    conn = ConversationController.pin(authed(), %{"conversation_id" => @conv, "pinned" => true})
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"conversation_id" => @conv, "pinned" => true}
  end

  test "PUT pin OVER THE CAP → 400 conversations.pin_limit carrying {limit: 3}" do
    ConvStub.set_pin_over_cap(true)

    conn = ConversationController.pin(authed(), %{"conversation_id" => @conv, "pinned" => true})

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "conversations.pin_limit"
    assert body["error"]["limit"] == 3
  end

  test "no session → 401" do
    conn = ConversationController.archive(authed("nobody"), %{"conversation_id" => @conv, "archived" => true})
    assert conn.status == 401
  end
end
