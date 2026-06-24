defmodule ConversationService.HTTP.Router do
  @moduledoc """
  Internal HTTP API for conversation-service (Plug, not Phoenix). Routes map 1:1 to
  `SharedInfra.ConversationClient`'s contract; each calls the in-process
  `ConversationService.{Conversations,Participants}` function and serializes via
  `SharedInfra.InternalApi.encode_result/1` (preserving error atoms — e.g. `:conversation_forbidden`,
  `:participant_invalid` — that the gateway pattern-matches on). Same template as
  `AuthService.HTTP.Router`. Transport auth via `SharedInfra.InternalApi.TokenPlug`.

  Started ONLY under `CONVERSATION_HTTP_API_ENABLED` (see `ConversationService.Application`),
  default off → no listener at boot. See docs/09-devops/INTERNAL_API.md.
  """
  use Plug.Router

  plug(SharedInfra.InternalApi.TokenPlug)
  plug(SharedInfra.InternalApi.CorrelationPlug)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:dispatch)

  post "/internal/conversations/create" do
    send_result(conn, ConversationService.Conversations.create_conversation(body(conn)))
  end

  post "/internal/conversations/list" do
    send_result(conn, ConversationService.Conversations.list_conversations(body(conn)))
  end

  post "/internal/conversations/get" do
    send_result(conn, ConversationService.Conversations.get_conversation(body(conn)))
  end

  post "/internal/participants/add" do
    send_result(conn, ConversationService.Participants.add_participant(body(conn)))
  end

  post "/internal/participants/remove" do
    send_result(conn, ConversationService.Participants.remove_participant(body(conn)))
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{"error" => "not_found"}))
  end

  defp body(%{body_params: params}) when is_map(params) and not is_struct(params), do: params
  defp body(_conn), do: %{}

  defp send_result(conn, result) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(SharedInfra.InternalApi.encode_result(result)))
  end
end
