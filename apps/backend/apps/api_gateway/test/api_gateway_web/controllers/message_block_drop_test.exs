defmodule ApiGatewayWeb.MessageBlockDropTest do
  @moduledoc """
  The REST send caller's handling of the block disposition (the socket path mirrors it). When the send gate
  (authorize_send) returns delivery: "drop" for a DIRECT chat the recipient blocked:

    * the message is sent to the store as `delivery_disposition: "drop"` (→ a synthesized canonical ack, no
      persist/publish), so the SENDER still gets a 201 (single tick, learns nothing), AND
    * the inbox fan-out that would wake the BLOCKER's conversation list is SKIPPED — the blocker is notified
      through no path.

  A normal (allowed) send does neither. Stubs AuthClient / ConversationClient / MessageClient — no DB.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.MessageController

  # @me lives in AuthStub (the session identity); the test body only needs the conversation id.
  @conv "44444444-4444-4444-8444-444444444444"

  defmodule AuthStub do
    @me "11111111-1111-4111-8111-111111111111"
    @app "33333333-3333-4333-8333-333333333333"
    def current_session(%{"authorization" => "Bearer me"}), do: {:ok, %{user_id: @me, app_id: @app}}
    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConvStub do
    def start_link, do: Agent.start_link(fn -> %{drop: false} end, name: __MODULE__)
    def set_drop(v), do: Agent.update(__MODULE__, &Map.put(&1, :drop, v))

    # Membership gate AND the fan_out_targets source for broadcast_updated.
    def get_conversation(_attrs),
      do: {:ok, %{participants: [%{user_id: "11111111-1111-4111-8111-111111111111"}]}}

    def authorize_send(_attrs) do
      if Agent.get(__MODULE__, & &1.drop),
        do: {:ok, %{authorized: true, delivery: "drop"}},
        else: {:ok, %{authorized: true}}
    end

    # Called by the inbox fan-out (broadcast_updated). We signal the test so a DROP can prove it's SKIPPED.
    def inbox_rows(_attrs) do
      send(:msg_block_drop_test, :inbox_rows_called)
      {:ok, %{rows: []}}
    end
  end

  defmodule MsgStub do
    def create_message(attrs) do
      send(:msg_block_drop_test, {:create_message, attrs})
      {:ok, %{message_id: "m1", conversation_id: attrs["conversation_id"], status: "active"}}
    end
  end

  setup do
    Process.register(self(), :msg_block_drop_test)
    start_supervised!(%{id: ConvStub, start: {ConvStub, :start_link, []}})

    prev = %{
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      conv: Application.get_env(:shared_infra, :conversation_client_adapter),
      msg: Application.get_env(:shared_infra, :message_client_adapter),
      persist: Application.get_env(:message_service, :message_persistence)
    }

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)
    # Force the DB-backed controller path (create_message_from_store) — MessageClient is stubbed, so no DB.
    Application.put_env(:message_service, :message_persistence, true)

    on_exit(fn ->
      restore(:shared_infra, :auth_client_adapter, prev.auth)
      restore(:shared_infra, :conversation_client_adapter, prev.conv)
      restore(:shared_infra, :message_client_adapter, prev.msg)
      restore(:message_service, :message_persistence, prev.persist)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp send_text do
    :post
    |> conn("/x", %{})
    |> put_req_header("authorization", "Bearer me")
    |> MessageController.create(%{"conversation_id" => @conv, "message_type" => "text", "body" => "hi"})
  end

  test "BLOCKED: the send is flagged drop, sender gets 201, and the blocker's inbox is NOT woken" do
    ConvStub.set_drop(true)

    conn = send_text()
    assert conn.status == 201

    # The store call carried the server-set drop flag (→ synthesized ack, no persist).
    assert_receive {:create_message, attrs}
    assert attrs["delivery_disposition"] == "drop"

    # …and the inbox fan-out that would notify the blocker never ran.
    refute_receive :inbox_rows_called, 200
  end

  test "ALLOWED: no drop flag, and the inbox fan-out DOES run (control)" do
    ConvStub.set_drop(false)

    conn = send_text()
    assert conn.status == 201

    assert_receive {:create_message, attrs}
    refute Map.has_key?(attrs, "delivery_disposition")

    assert_receive :inbox_rows_called, 500
  end
end
