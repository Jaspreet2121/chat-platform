defmodule ApiGatewayWeb.MediaAuthz do
  @moduledoc """
  The single, shared END-USER media-DOWNLOAD authorization rule, keyed on the asset's purpose. Extracted
  from `ApiGatewayWeb.MediaController` so the first-party (session) and public `/v1` (V1Auth) media
  controllers apply the SAME rule — two copies of an authorization rule is how the earlier media holes
  happened.

    * message      → the conversation the media was SENT to (`messages.media_id` → conversation_id) →
                     membership; if it isn't attached to a message yet (uploaded, not sent) → owner-only.
    * group_avatar → the asset's `conversation_id` (set on upload) → membership.
    * user_avatar  → any authenticated same-app caller (`get_asset` already scoped `app_id`).

  Runs in the GATEWAY (it can reach conversation_service; the media service can't). The `/v1` `:app` actor
  does NOT use this — it authorizes on tenant scope alone. Every failure is a coarse `{:error, :not_a_member}`
  (or `:conversation_unavailable`) that callers collapse to 404 — no existence reveal, never 403.
  """

  alias SharedInfra.ConversationClient
  alias SharedInfra.MessageClient

  @spec authorize_download(String.t(), map(), String.t()) :: :ok | {:error, atom()}
  def authorize_download(media_id, asset, user_id) do
    case aget(asset, :purpose) do
      "message" -> authorize_message_media(media_id, asset, user_id)
      "group_avatar" -> authorize_group_avatar(asset, user_id)
      "user_avatar" -> :ok
      _ -> {:error, :not_a_member}
    end
  end

  defp authorize_message_media(media_id, asset, user_id) do
    case MessageClient.get_by_media_id(%{"media_id" => media_id}) do
      {:ok, result} ->
        case aget(result, :conversation_id) do
          conversation_id when is_binary(conversation_id) -> membership(conversation_id, user_id)
          # Attached to no readable conversation → fall back to owner-only.
          _ -> owner_only(asset, user_id)
        end

      {:error, :message_unavailable} ->
        {:error, :conversation_unavailable}

      # Not attached to any message (uploaded, not sent) → only the owner may download it.
      _ ->
        owner_only(asset, user_id)
    end
  end

  defp authorize_group_avatar(asset, user_id) do
    case aget(asset, :conversation_id) do
      conversation_id when is_binary(conversation_id) -> membership(conversation_id, user_id)
      _ -> {:error, :not_a_member}
    end
  end

  # get_conversation with the caller's user_id runs fetch_active_participant (active membership).
  defp membership(conversation_id, user_id) do
    case ConversationClient.get_conversation(%{
           "conversation_id" => conversation_id,
           "user_id" => user_id
         }) do
      {:ok, _conversation} -> :ok
      {:error, :conversation_unavailable} -> {:error, :conversation_unavailable}
      _ -> {:error, :not_a_member}
    end
  end

  defp owner_only(asset, user_id) do
    if aget(asset, :owner_user_id) == user_id, do: :ok, else: {:error, :not_a_member}
  end

  defp aget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp aget(_map, _key), do: nil
end
