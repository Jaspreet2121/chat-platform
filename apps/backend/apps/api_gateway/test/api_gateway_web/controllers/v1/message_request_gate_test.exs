defmodule ApiGatewayWeb.V1.MessageRequestGateTest do
  @moduledoc """
  THE /v1 PARTNER PATH IS GATED TOO (128).

  MUT-9 guard: a /v1 send bypasses the request gate → RED.

  /v1 has never run `authorize_send` — it calls `MessageClient.create_message` directly — so it
  enforces neither only-admins-can-send nor the block-drop. That is exactly why the stranger budget
  was put in `MessageService.Messages.create_message/1` instead: the deepest point all three send
  paths funnel through. `MessageService.MessageRequestBudgetTest` proves the budget fires at that
  seam; this proves /v1 SURFACES the refusal as a named 429 rather than a generic "invalid request"
  a partner integration could only read as its own bug.

  Moving the gate up to `authorize_send` turns both suites red: the budget one because the seam stops
  firing, this one because the error never arrives.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.V1.MessageController

  @app "44444444-4444-4444-8444-444444444444"
  @conversation "11111111-1111-4111-8111-111111111111"
  @sender "22222222-2222-4222-8222-222222222222"

  defmodule ConvStub do
    @moduledoc false
    def get_conversation(%{"conversation_id" => id}) do
      {:ok,
       %{
         conversation_id: id,
         app_id: "44444444-4444-4444-8444-444444444444",
         type: "direct",
         participants: [%{user_id: "22222222-2222-4222-8222-222222222222"}]
       }}
    end
  end

  # The budget refusal as message-service returns it — the one thing /v1 must not swallow.
  defmodule LimitedMsgStub do
    @moduledoc false
    def create_message(_attrs), do: {:error, :message_request_limit}
  end

  defmodule OkMsgStub do
    @moduledoc false
    def create_message(_attrs),
      do: {:ok, %{"message_id" => "m1", "body" => "hi", "status" => "active"}}
  end

  setup do
    previous = %{
      conv: Application.get_env(:shared_infra, :conversation_client_adapter),
      msg: Application.get_env(:shared_infra, :message_client_adapter)
    }

    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)

    on_exit(fn ->
      restore(:conversation_client_adapter, previous.conv)
      restore(:message_client_adapter, previous.msg)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  defp send_v1 do
    params = %{"id" => @conversation, "body" => "hello", "user_id" => @sender}

    :post
    |> conn("/v1/conversations/#{@conversation}/messages", params)
    |> assign(:v1_app_id, @app)
    |> assign(:v1_user_id, @sender)
    |> MessageController.create(params)
  end

  test "MUT-9 guard: the budget refusal reaches a /v1 caller as a named 429" do
    Application.put_env(:shared_infra, :message_client_adapter, LimitedMsgStub)

    conn = send_v1()

    assert conn.status == 429
    assert conn.resp_body =~ "v1.message_request_limit"
    assert [retry] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry) > 0
  end

  test "an ordinary /v1 send is untouched" do
    Application.put_env(:shared_infra, :message_client_adapter, OkMsgStub)

    assert send_v1().status == 201
  end
end
