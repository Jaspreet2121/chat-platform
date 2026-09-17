defmodule ApiGatewayWeb.ChecklistCreateErrorsTest do
  @moduledoc """
  FOUND ON DEVICE: a malformed checklist create surfaced as a generic error on both send paths, so
  a client could not tell "that list is too long" from "something went wrong". The domain had named
  every failure; neither create path mapped them.

  Both paths are pinned here — REST in this module, the socket in its sibling — because a checklist
  can be sent on either, and a code that exists on only one is the drift this codebase keeps
  catching.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.MessageController

  @conversation "11111111-1111-4111-8111-111111111111"

  defmodule AuthStub do
    @moduledoc false
    def current_session(_),
      do: {:ok, %{user_id: "22222222-2222-4222-8222-222222222222", app_id: "app1"}}
  end

  defmodule ConvStub do
    @moduledoc false
    def get_conversation(_), do: {:ok, %{conversation_id: "11111111-1111-4111-8111-111111111111"}}
    def get_conversation_app(_), do: {:ok, %{}}
    def authorize_send(_), do: {:ok, %{authorized: true}}
  end

  defmodule MsgStub do
    @moduledoc false
    def create_message(_attrs),
      do: {:error, Application.get_env(:api_gateway, :checklist_create_error)}
  end

  setup do
    keys = [
      {:shared_infra, :auth_client_adapter},
      {:shared_infra, :conversation_client_adapter},
      {:shared_infra, :message_client_adapter},
      {:api_gateway, :checklist_create_error},
      {:message_service, :message_persistence}
    ]

    prev = for {app, key} <- keys, into: %{}, do: {{app, key}, Application.get_env(app, key)}

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)
    Application.put_env(:message_service, :message_persistence, true)

    on_exit(fn ->
      for {{app, key}, value} <- prev do
        if value == nil,
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end
    end)

    :ok
  end

  defp create(error) do
    Application.put_env(:api_gateway, :checklist_create_error, error)

    :post
    |> conn("/x", %{})
    |> put_req_header("authorization", "Bearer x")
    |> MessageController.create(%{
      "conversation_id" => @conversation,
      "message_type" => "checklist",
      "body" => "Weekend shop"
    })
  end

  defp code(conn), do: Jason.decode!(conn.resp_body)["error"]["code"]

  test "MUT-3 guard: a 31-item create answers checklist.too_many_items, not a generic error" do
    conn = create(:checklist_too_many_items)
    assert conn.status == 422
    assert code(conn) == "checklist.too_many_items"
  end

  test "every named checklist failure carries its own code" do
    for {reason, status, expected} <- [
          {:checklist_not_in_sealed, 422, "checklist.not_in_sealed"},
          {:checklist_too_many_items, 422, "checklist.too_many_items"},
          {:checklist_text_too_long, 422, "checklist.text_too_long"},
          {:checklist_no_items, 400, "checklist.no_items"},
          {:checklist_invalid_item, 400, "checklist.invalid_item"},
          {:checklist_invalid_title, 400, "checklist.invalid_title"}
        ] do
      conn = create(reason)
      assert conn.status == status, "#{reason} gave #{conn.status}, expected #{status}"
      assert code(conn) == expected
    end
  end

  test "an unrelated failure still falls to the generic mapping — the new clauses did not widen" do
    conn = create(:message_invalid)
    assert conn.status == 400
    refute code(conn) =~ "checklist"
  end
end
