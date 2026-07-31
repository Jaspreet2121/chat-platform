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
      # Status media: the owning POST authorizes — it must be LIVE (expired/deleted → denied even with
      # the id in hand) and the viewer must pass the SAME audience predicate the status feed runs
      # (owner always allowed). Unknown purposes below stay denied — nothing else loosens.
      "status" -> authorize_status_media(media_id, user_id)
      _ -> {:error, :not_a_member}
    end
  end

  defp authorize_status_media(media_id, user_id) do
    case MessageClient.status_media_allowed(%{"media_id" => media_id, "viewer_user_id" => user_id}) do
      {:ok, result} ->
        if aget(result, :allowed) == true, do: :ok, else: {:error, :not_a_member}

      {:error, :message_unavailable} ->
        {:error, :conversation_unavailable}

      _ ->
        {:error, :not_a_member}
    end
  end

  # OWNER-ANCHORED message-media rule (replaces the oldest-message-wins resolve, which authorized a
  # reused media_id against exactly ONE conversation — breaking BROADCASTS for recipients 2..N): the
  # viewer may download iff they are an active member of ANY conversation containing a message
  # referencing this media_id whose SENDER IS THE ASSET'S OWNER. The anchor is what makes widening
  # safe — message-create does NOT validate media ownership, so a user CAN plant a reference to
  # someone else's media_id in a conversation they control; anchored to sender=owner, that planted
  # message grants nobody anything.
  #
  # WHAT THIS DOES *NOT* FIX — read before removing any client workaround: forwarding media SOMEONE
  # ELSE SENT YOU still fails. A uploads M and sends it in A↔B; B forwards to C by reusing M; C
  # qualifies only via a conversation where *A* sent M, and A only ever sent it to A↔B — so C is
  # DENIED. Only forwarding YOUR OWN media works (you are the owner, so your sends qualify).
  # Re-upload-on-forward therefore remains REQUIRED for received media (Android does this; apps/web
  # does it too, unconditionally, in reuploadMediaForForward).
  #
  # The OWNER themselves may always download (also covers uploaded-not-yet-sent, preserving the old
  # owner-only fallback). One indexed EXISTS (083), never a scan.
  defp authorize_message_media(media_id, asset, user_id) do
    with {:owner, false} <- {:owner, aget(asset, :owner_user_id) == user_id},
         {:ok, result} <-
           MessageClient.media_download_allowed(%{
             "media_id" => media_id,
             "owner_user_id" => aget(asset, :owner_user_id),
             "viewer_user_id" => user_id
           }) do
      if aget(result, :allowed) == true, do: :ok, else: {:error, :not_a_member}
    else
      {:owner, true} -> :ok
      {:error, :message_unavailable} -> {:error, :conversation_unavailable}
      _ -> {:error, :not_a_member}
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

  defp aget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp aget(_map, _key), do: nil
end
