defmodule MessageService.HTTP.RouterTest do
  @moduledoc """
  Drives the message internal HTTP API via Plug.Test (synthetic conn — NO listener/port),
  plain/Docker-free on the persistence-off (placeholder) paths. Asserts `decode_result(body)`
  reconstructs the exact in-process shape for Messages / Timeline / Receipts routes (incl. the
  atom-keyed message + nested timeline list) + the internal-auth plug rejection. Error-atom
  round-trip is covered in `SharedInfra.InternalApiTest`.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @opts MessageService.HTTP.Router.init([])
  @token "test-internal-token"

  setup do
    previous = Application.get_env(:shared_infra, :internal_api_token)
    Application.put_env(:shared_infra, :internal_api_token, @token)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shared_infra, :internal_api_token, previous),
        else: Application.delete_env(:shared_infra, :internal_api_token)
    end)

    :ok
  end

  defp call(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-internal-token", @token)
    |> MessageService.HTTP.Router.call(@opts)
  end

  test "POST /internal/messages/create — envelope + decode matches in-process (atom-keyed message)" do
    attrs = %{
      "conversation_id" => "conv_1",
      "sender_user_id" => "u1",
      "message_type" => "text",
      "body" => "hi"
    }

    conn = call("/internal/messages/create", attrs)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert %{"ok" => _} = body

    assert SharedInfra.InternalApi.decode_result(body) ==
             MessageService.Messages.create_message(attrs)
  end

  test "POST /internal/messages/list — decode matches Messages.list_messages" do
    attrs = %{"conversation_id" => "conv_1"}
    body = call("/internal/messages/list", attrs).resp_body |> Jason.decode!()

    assert SharedInfra.InternalApi.decode_result(body) ==
             MessageService.Messages.list_messages(attrs)
  end

  test "POST /internal/timeline/list — decode matches Timeline.list_messages (the list_timeline route)" do
    attrs = %{"conversation_id" => "conv_1"}
    body = call("/internal/timeline/list", attrs).resp_body |> Jason.decode!()

    assert SharedInfra.InternalApi.decode_result(body) ==
             MessageService.Timeline.list_messages(attrs)
  end

  test "POST /internal/receipts/mark_read — decode matches Receipts.mark_read" do
    attrs = %{"conversation_id" => "conv_1", "message_id" => "m1", "user_id" => "u1"}
    body = call("/internal/receipts/mark_read", attrs).resp_body |> Jason.decode!()
    assert SharedInfra.InternalApi.decode_result(body) == MessageService.Receipts.mark_read(attrs)
  end

  test "rejects (401) a request missing the internal token" do
    conn =
      conn(:post, "/internal/messages/list", Jason.encode!(%{}))
      |> put_req_header("content-type", "application/json")
      |> MessageService.HTTP.Router.call(@opts)

    assert conn.status == 401
    assert conn.halted
  end
end
