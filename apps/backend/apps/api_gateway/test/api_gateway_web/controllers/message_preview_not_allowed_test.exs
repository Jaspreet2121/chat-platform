defmodule ApiGatewayWeb.MessagePreviewNotAllowedTest do
  @moduledoc """
  The message service's :preview_not_allowed (a sealed message carrying a plaintext preview) reaches
  the REST sender as 422 message.preview_not_allowed — not the generic invalid_request.
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
    def authorize_send(_), do: {:ok, %{authorized: true}}
  end

  defmodule MsgStub do
    @moduledoc false
    def create_message(_attrs), do: {:error, :preview_not_allowed}
  end

  setup do
    keys = [:auth_client_adapter, :conversation_client_adapter, :message_client_adapter]
    prev = for k <- keys, into: %{}, do: {k, Application.get_env(:shared_infra, k)}
    prev_persist = Application.get_env(:message_service, :message_persistence)

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)
    Application.put_env(:message_service, :message_persistence, true)

    on_exit(fn ->
      for {k, v} <- prev do
        if v,
          do: Application.put_env(:shared_infra, k, v),
          else: Application.delete_env(:shared_infra, k)
      end

      if prev_persist,
        do: Application.put_env(:message_service, :message_persistence, prev_persist),
        else: Application.delete_env(:message_service, :message_persistence)
    end)

    :ok
  end

  test "sealed + preview → 422 message.preview_not_allowed" do
    conn =
      :post
      |> conn("/api/v1/conversations/#{@conversation}/messages", %{})
      |> put_req_header("authorization", "Bearer x")
      |> MessageController.create(%{
        "conversation_id" => @conversation,
        "message_type" => "sealed",
        "client_msg_id" => "c1",
        "sealed" => %{"v" => 1},
        "preview" => %{"inline_b64" => "AAAA", "w" => 1, "h" => 1}
      })

    assert conn.status == 422

    assert %{"error" => %{"code" => "message.preview_not_allowed"}} =
             Jason.decode!(conn.resp_body)
  end
end
