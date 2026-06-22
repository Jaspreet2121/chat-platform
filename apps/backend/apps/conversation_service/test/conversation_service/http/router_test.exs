defmodule ConversationService.HTTP.RouterTest do
  @moduledoc """
  Drives the conversation internal HTTP API via Plug.Test (synthetic conn — NO listener/port),
  plain/Docker-free on the persistence-off (placeholder) paths. Asserts the internal result-envelope
  + that `decode_result` reconstructs the exact in-process shape (incl. atom-keyed maps) + the
  internal-auth plug rejection. Error-atom round-trip is covered in `SharedInfra.InternalApiTest`.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @opts ConversationService.HTTP.Router.init([])
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
    |> ConversationService.HTTP.Router.call(@opts)
  end

  test "POST /internal/conversations/get returns {\"ok\": detail} and decode reconstructs the in-process shape" do
    attrs = %{"conversation_id" => "conv_1", "user_id" => "user_1"}
    conn = call("/internal/conversations/get", attrs)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert %{"ok" => _} = body
    # Fidelity: the atom-keyed detail map round-trips back to the exact in-process result.
    assert SharedInfra.InternalApi.decode_result(body) ==
             ConversationService.Conversations.get_conversation(attrs)
  end

  test "POST /internal/conversations/create returns an {\"ok\": ...} envelope (placeholder path)" do
    attrs = %{"type" => "group", "created_by" => "user_1", "participant_user_ids" => ["user_2"]}
    conn = call("/internal/conversations/create", attrs)
    assert conn.status == 200
    assert %{"ok" => _} = Jason.decode!(conn.resp_body)
  end

  test "POST /internal/participants/add returns {\"ok\": participant}; decode matches in-process" do
    attrs = %{
      "conversation_id" => "conv_1",
      "user_id" => "user_2",
      "actor_user_id" => "user_1",
      "role" => "member"
    }

    conn = call("/internal/participants/add", attrs)
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert SharedInfra.InternalApi.decode_result(body) ==
             ConversationService.Participants.add_participant(attrs)
  end

  test "rejects (401) a request missing the internal token" do
    conn =
      conn(:post, "/internal/conversations/get", Jason.encode!(%{}))
      |> put_req_header("content-type", "application/json")
      |> ConversationService.HTTP.Router.call(@opts)

    assert conn.status == 401
    assert conn.halted
  end
end
