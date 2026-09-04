defmodule SharedInfra.MediaAttachPolicy do
  @moduledoc """
  MAY THIS SENDER ATTACH THIS `media_id`? The single rule for every first-party path that puts a
  `media_id` on a message.

  ## Why this exists

  `/v1` has enforced this since it shipped (`ApiGatewayWeb.V1.MessageController.validate_media/3`): a
  media attachment must be a READY asset, of an attachable purpose, in the caller's app, and — for an
  end-user actor — OWNED by the caller. The first-party paths enforced NONE of it: `media_id` was
  taken from client params and handed to `create_message` unvalidated. The less-trusted B2B surface
  was the better-guarded one.

  That gap was the enabling half of a CRITICAL: attach a victim's `media_id` to a `view_once` message,
  have a second account open it, and the view-once purge deletes the victim's blob. The other half is
  closed independently in `MediaService.Media.purge_asset/1`, which now matches on `owner_user_id` —
  either fix alone stops that exploit, and BOTH are deliberately kept (see the belt-and-braces note
  there). This one additionally stops the broader class: referencing someone else's asset at all.

  ## Why shared_infra and not the gateway

  THREE first-party surfaces attach media, and they do not live in one app:

    * `ApiGatewayWeb.MessageController` — first-party REST create (what the mobile clients use);
    * `ApiGatewayWeb.BroadcastController` — the broadcast fan-out, which passes `media_id` straight
      through `@message_fields` into one `create_message` PER RECIPIENT;
    * `RealtimeGateway.ConversationChannel` — `message:create` / `message:new` over the socket.

  A rule that only covered the REST controller would leave the exploit reachable from the other two,
  which is exactly how "fixed" becomes "moved". `realtime_gateway` cannot see `ApiGatewayWeb`, so the
  rule lives here — the same reason `SharedInfra.ConversationBroadcast` does.

  ## The rule

  `:ok` when there is nothing to check (no `media_id`, or a SEALED message — whose `media_id` is
  forced nil by `MessageService.Messages.media_id/2` because the descriptor rides inside the encrypted
  envelope, so validating a value that is about to be discarded could only ever reject a legitimate
  send). Otherwise the asset must resolve, and:

    * `app_id` — the tenant it was uploaded under matches the caller's;
    * `owner_user_id` — the sender uploaded it;
    * `status == "ready"` — a `created`/`uploading` asset has no verified bytes behind it yet
      (`Media.verify_uploaded_size/1` is what promotes it, and that is the size-cap boundary);
    * `purpose` in `@attachable_purposes`.

  ONE ERROR FOR EVERY FAILURE (`:media_invalid`). An unknown id, another tenant's id, another user's
  id and a not-yet-ready id are indistinguishable to the caller — the same no-existence-leak rule the
  download path follows by collapsing everything to 404.

  FAILS CLOSED. An unreachable media service means the attachment cannot be proven safe, and the
  send is refused rather than admitted unchecked.
  """

  require Logger

  # Only `message` assets belong on a message. Deliberately NOT here:
  #   * `sealed_media` — never attached as a top-level media_id (see the moduledoc);
  #   * `user_avatar` / `group_avatar` — profile and group artefacts, and `user_avatar` is readable by
  #     any authenticated same-app caller, so admitting it would let a message launder a broadly
  #     readable asset into a conversation-anchored one;
  #   * `status` — status posts carry their own table and their own purge;
  #   * `user_asset` — server-generated (the UPI QR), attached to a profile, and already refused at
  #     upload by `MediaController`'s `@upload_purposes`.
  @attachable_purposes ["message"]

  @doc """
  Validate a message's media attachment. `params` is the raw client payload (string- or atom-keyed).

  Returns `:ok` or `{:error, :media_invalid}`.
  """
  @spec validate(map(), String.t(), String.t() | nil) :: :ok | {:error, :media_invalid}
  def validate(params, sender_user_id, app_id) when is_map(params) do
    case attachable_media_id(params) do
      nil -> :ok
      media_id -> check(media_id, sender_user_id, app_id)
    end
  end

  def validate(_params, _sender_user_id, _app_id), do: :ok

  # Mirrors MessageService.Messages.media_id/2: a sealed message never attaches one.
  defp attachable_media_id(params) do
    case get(params, "message_type") do
      "sealed" ->
        nil

      _ ->
        case get(params, "media_id") do
          id when is_binary(id) and id != "" -> id
          _ -> nil
        end
    end
  end

  defp check(media_id, sender_user_id, app_id) do
    case SharedInfra.MediaClient.get_asset(asset_query(media_id, app_id)) do
      {:ok, asset} ->
        if owned?(asset, sender_user_id) and ready?(asset) and attachable?(asset) do
          :ok
        else
          # WARN, not debug: a mismatch here is either a client bug or someone referencing an asset
          # they do not own. Both are worth seeing; neither is worth failing loudly to the caller.
          Logger.warning(
            "media attach refused media=#{media_id} sender=#{sender_user_id} " <>
              "owner=#{inspect(aget(asset, :owner_user_id))} status=#{inspect(aget(asset, :status))} " <>
              "purpose=#{inspect(aget(asset, :purpose))}"
          )

          {:error, :media_invalid}
        end

      other ->
        # Unknown id, another tenant's id, or the media service being unreachable — all refuse, and
        # all refuse IDENTICALLY. The caller cannot tell which.
        Logger.warning(
          "media attach refused media=#{media_id} sender=#{sender_user_id}: #{inspect(other)}"
        )

        {:error, :media_invalid}
    end
  end

  # app_id is omitted when the caller has none rather than sent as nil: `get_asset` treats a present
  # app_id as a scope filter, and a nil filter would match nothing and refuse every attachment.
  defp asset_query(media_id, app_id) when is_binary(app_id) and app_id != "",
    do: %{"media_id" => media_id, "app_id" => app_id}

  defp asset_query(media_id, _app_id), do: %{"media_id" => media_id}

  defp owned?(asset, sender_user_id),
    do:
      is_binary(sender_user_id) and sender_user_id != "" and
        aget(asset, :owner_user_id) == sender_user_id

  defp ready?(asset), do: aget(asset, :status) == "ready"

  defp attachable?(asset), do: aget(asset, :purpose) in @attachable_purposes

  # Both key shapes, WITHOUT String.to_existing_atom: this runs on the send path, and an atom that
  # happens not to be loaded would raise inside a validation whose entire job is to refuse safely.
  defp get(params, "message_type"),
    do: Map.get(params, "message_type") || Map.get(params, :message_type)

  defp get(params, "media_id"), do: Map.get(params, "media_id") || Map.get(params, :media_id)

  defp aget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp aget(_map, _key), do: nil
end
