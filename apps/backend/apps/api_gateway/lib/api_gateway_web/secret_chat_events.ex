defmodule ApiGatewayWeb.SecretChatEvents do
  @moduledoc """
  Secret-chat system events (108). Two jobs, both BEST-EFFORT by construction (rescue-all — a
  hiccup here must never fail the operation that triggered it):

    * `system_message/3` — write a plaintext SYSTEM message (protocol state, never user content)
      through the normal message path and fan it out on the conversation topic.
    * `emit_keys_changed/1` — when a user's device-key set changes (upload/rotation or a session
      revoke), every SECRET conversation they belong to gets a {kind: "encryption",
      state: "keys_changed", user} system message, so both clients can re-verify safety numbers.
  """

  require Logger

  def emit_keys_changed(user_id) do
    case SharedInfra.ConversationClient.secret_conversations_of(%{"user_id" => user_id}) do
      {:ok, result} ->
        ids = Map.get(result, :conversation_ids) || Map.get(result, "conversation_ids") || []

        for conversation_id <- ids do
          system_message(conversation_id, user_id, %{
            "kind" => "encryption",
            "state" => "keys_changed",
            "user" => user_id
          })
        end

        :ok

      _ ->
        :ok
    end
  rescue
    error ->
      Logger.warning("secret keys_changed emission skipped: #{inspect(error)}")
      :ok
  end

  def system_message(conversation_id, sender_user_id, metadata) do
    case SharedInfra.MessageClient.create_message(%{
           "conversation_id" => conversation_id,
           "sender_user_id" => sender_user_id,
           "message_type" => "system",
           "metadata" => metadata
         }) do
      {:ok, response} ->
        ApiGatewayWeb.Endpoint.broadcast(
          "conversation:" <> conversation_id,
          "message_created",
          response
        )

        :ok

      other ->
        Logger.warning("secret system message failed for #{conversation_id}: #{inspect(other)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("secret system message raised: #{inspect(error)}")
      :ok
  end
end
