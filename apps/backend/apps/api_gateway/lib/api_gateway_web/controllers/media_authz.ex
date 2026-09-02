defmodule ApiGatewayWeb.MediaAuthz do
  @moduledoc """
  The single, shared END-USER media-DOWNLOAD authorization rule, keyed on the asset's purpose. Extracted
  from `ApiGatewayWeb.MediaController` so the first-party (session) and public `/v1` (V1Auth) media
  controllers apply the SAME rule — two copies of an authorization rule is how the earlier media holes
  happened.

    * message      → the conversation the media was SENT to (`messages.media_id` → conversation_id) →
                     membership; if it isn't attached to a message yet (uploaded, not sent) → owner-only.
    * sealed_media → the asset's `conversation_id` (set on upload) → membership. It CANNOT use the
                     message rule: a sealed message's `media_id` column is forced NULL (the descriptor
                     rides inside the encrypted envelope), so the message-anchored oracle finds no
                     reference and denies every recipient.
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
    # VIEW-ONCE (115) RUNS BEFORE THE PURPOSE DISPATCH, and it has to: inside
    # authorize_message_media/3 the owner short-circuit fires first, so a sender-side deny placed
    # there would be dead code — the sender IS the owner.
    #
    # THE AGREEMENT PROPERTY, which is the whole safety argument: for any media not referenced by a
    # view_once=true message, this function returns exactly what it returned before, having executed
    # exactly the same code path. `:not_view_once` is therefore also what a FAILING probe returns
    # (see ViewOnce.state/2's rescue) — this gate is an extra restriction on a narrow feature, never
    # a new dependency for every download in the system. Failing closed here would turn one bad
    # query into a total media outage.
    case view_once_state(media_id, user_id) do
      :not_view_once -> authorize_by_purpose(media_id, asset, user_id)
      # The viewer may read it exactly once more.
      :unopened -> authorize_by_purpose(media_id, asset, user_id)
      # One-way: a sender who could re-read their own send would keep a copy of what the recipient
      # believes is gone.
      :sender -> {:error, :not_a_member}
      :opened -> {:error, :not_a_member}
      :expired -> {:error, :not_a_member}
    end
  end

  # 120 seconds for view-once media. Long enough for a client to follow the URL it just asked for,
  # short enough that a URL issued moments before an open cannot be replayed for long afterwards.
  @view_once_url_expires_seconds 120

  @doc """
  Add a presign-lifetime ceiling to a download request when the media is view-once.

  Returns the attrs UNCHANGED for ordinary media — the agreement property covers the presign path
  too: a non-view-once download is signed exactly as it was before.
  """
  def put_download_ttl(attrs, media_id, user_id) do
    case view_once_state(media_id, user_id) do
      :not_view_once -> attrs
      _ -> Map.put(attrs, "url_expires_seconds", @view_once_url_expires_seconds)
    end
  end

  # RESCUES, not just an error-tuple fallback. A message client that does not implement this callback
  # RAISES UndefinedFunctionError rather than returning {:error, _} — which is what an older adapter,
  # a partial test double, or a mid-deploy release skew all look like. Catching only the tuple left
  # every media download in the system one missing callback away from a 404, and the agreement
  # property could not see it because the stub implemented the callback.
  #
  # The rule is the same at every layer: a broken view-once probe means "not view-once", never "deny".
  defp view_once_state(media_id, user_id) do
    case MessageClient.view_once_state(%{
           "media_id" => media_id,
           "viewer_user_id" => user_id
         }) do
      {:ok, result} -> decode_state(aget(result, :state))
      _ -> :not_view_once
    end
  rescue
    _ -> :not_view_once
  catch
    _, _ -> :not_view_once
  end

  defp decode_state("sender"), do: :sender
  defp decode_state("opened"), do: :opened
  defp decode_state("expired"), do: :expired
  defp decode_state("unopened"), do: :unopened
  defp decode_state(_), do: :not_view_once

  defp authorize_by_purpose(media_id, asset, user_id) do
    case aget(asset, :purpose) do
      "message" -> authorize_message_media(media_id, asset, user_id)
      # user_asset (113): a SERVER-GENERATED asset owned by a user with no conversation of its own —
      # today only the UPI QR PNG. It exists so such assets stop being minted as anchorless
      # purpose="message" rows, NOT because their ACL differs: the /qr slash command sends the QR into
      # a chat as an ordinary media message by id, so a recipient fetches THIS media_id and must be
      # authorized exactly as they would be for any attachment. Owner-only here would 404 every QR
      # anyone has ever sent. Same rule, different provenance.
      "user_asset" -> authorize_message_media(media_id, asset, user_id)
      # sealed_media: CANNOT use the message-media rule — see authorize_sealed_media/2.
      "sealed_media" -> authorize_sealed_media(asset, user_id)
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
    case MessageClient.status_media_allowed(%{
           "media_id" => media_id,
           "viewer_user_id" => user_id
         }) do
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

  # SEALED MEDIA IS AUTHORIZED BY THE ASSET'S CONVERSATION, NOT BY A MESSAGE.
  #
  # This was a total outage for E2EE attachments: sealed_media originally routed to
  # authorize_message_media/3, whose oracle asks "is there a message referencing this media_id whose
  # sender is the owner?". For a sealed message there is never such a row — `media_id` is forced NULL
  # at creation (MessageService.Messages.media_id/2) because the descriptor lives INSIDE the encrypted
  # frame and the server cannot read it. So the oracle returned allowed:false for every recipient and
  # the controller collapsed that to 404. The OWNER short-circuit hid it from the sender, which is why
  # it looked purpose-specific rather than transport-specific: sealed photo AND sealed video both
  # 404'd for the recipient, while plaintext of either kind worked.
  #
  # The asset's conversation_id is the right anchor, and it is exactly as tight: it was written at
  # UPLOAD time from the authenticated uploader's request, and MediaController.authorize_upload/3
  # already refused that upload unless the uploader was an active member of it. So downloading
  # requires active membership of the same conversation the ciphertext was uploaded for. A planted
  # asset grants nothing: its uploader can only name a conversation they belong to, and only members
  # of THAT conversation can read it.
  #
  # No conversation_id (an older or non-conversational sealed upload) → owner-only, the safe default.
  defp authorize_sealed_media(asset, user_id) do
    cond do
      aget(asset, :owner_user_id) == user_id ->
        :ok

      is_binary(aget(asset, :conversation_id)) and aget(asset, :conversation_id) != "" ->
        membership(aget(asset, :conversation_id), user_id)

      true ->
        {:error, :not_a_member}
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
