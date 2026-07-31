defmodule ApiGatewayWeb.ProfilePresenter do
  @moduledoc """
  The SINGLE home of the "profile as the caller may see it" rule — block + `profile_photo_visibility`
  redaction plus avatar-URL presigning. Extracted from `UserController` so every path that reveals a
  profile to a caller runs the SAME code and cannot drift: the single by-phone lookup, the public
  profile, the avatar redirect, AND the bulk contacts-sync match. Because bulk matching is the widest
  fan-out of "who is this number", it MUST apply exactly the redaction a single lookup applies — this
  module is what guarantees it (there is no second implementation to keep in sync).

  All visibility checks fail CLOSED (a client error hides rather than reveals), matching presence.
  """

  # Profile as the CALLER may see it. The avatar is HIDDEN when there's a block (either direction) OR the
  # target's `profile_photo_visibility` doesn't permit this caller — in both cases the account still exists
  # (name shown) and the result is byte-identical to a user with no avatar, so neither the block nor the
  # visibility setting is ever revealed. Last-seen/online is a SEPARATE surface (SharedInfra.PresenceAuthz).
  def present(caller_id, target_id, profile) when is_map(profile) do
    if avatar_hidden?(caller_id, target_id) do
      # Skip the presign entirely and drop the raw avatar id (so the client can't resolve it itself) + the
      # internal app_id; avatar_url: nil is the same shape a genuinely-avatarless profile returns.
      profile
      |> Map.drop([
        :avatar_media_id,
        "avatar_media_id",
        :avatar_object_key,
        "avatar_object_key",
        :app_id
      ])
      |> Map.put(:avatar_url, nil)
    else
      with_avatar_url(profile)
    end
  end

  def present(_caller_id, _target_id, other), do: other

  # The single "may this caller see the target's avatar?" rule, reused by every OTHER-user avatar path
  # (profile, by-phone, the avatar redirect, contacts sync). Block hides it BOTH ways; otherwise the
  # three-way profile_photo_visibility decides. Composes with the block slice's check — one place.
  def avatar_hidden?(caller_id, target_id) do
    either_blocked?(caller_id, target_id) or not photo_visible?(caller_id, target_id)
  end

  # Enrich a profile map with a ready-to-use signed `avatar_url`. The profile stores `avatar_media_id`
  # + `avatar_object_key`; presigning a download URL needs the object_key (a viewer can't reconstruct
  # another user's key), so the gateway resolves it via the media client and attaches `avatar_url`.
  # Best-effort: any missing field or media error just leaves the profile unchanged (no avatar_url).
  # Visibility gating (block + profile_photo_visibility) is applied UPSTREAM by present/avatar_hidden?
  # BEFORE this presign, so this helper only ever runs for an avatar the caller is permitted to see.
  def with_avatar_url(profile) when is_map(profile) do
    media_id = Map.get(profile, :avatar_media_id)
    app_id = Map.get(profile, :app_id)

    result =
      if is_binary(media_id) and is_binary(app_id) do
        # Presign scoped to the PROFILE's app (the /avatar route is unauthenticated → no caller app_id).
        # object_key is resolved server-side from the row; the "user_avatar" purpose assertion refuses to
        # presign a non-avatar asset (so a poisoned avatar_media_id can't presign a message attachment). On
        # any media error, leave the profile unchanged (fail-open) so a glitch never wipes a valid avatar.
        with {:ok, download} <-
               SharedInfra.MediaClient.get_download_url(%{
                 "media_id" => media_id,
                 "app_id" => app_id,
                 "purpose" => "user_avatar"
               }),
             url when is_binary(url) <- Map.get(download, :download_url) do
          Map.put(profile, :avatar_url, url)
        else
          _ -> profile
        end
      else
        # No avatar (never set, or just cleared) → avatar_url: nil EXPLICITLY so clients drop any stale URL.
        Map.put(profile, :avatar_url, nil)
      end

    # app_id is an INTERNAL presign input — never leak the tenant id to the client.
    Map.delete(result, :app_id)
  end

  def with_avatar_url(other), do: other

  # profile_photo_visibility three-way. everyone → any caller; contacts → only a shared-conversation caller;
  # nobody/unknown → hidden (fail-closed, like presence). The DEFAULT is "contacts", so a user with no
  # settings row shows their photo to contacts only.
  defp photo_visible?(caller_id, target_id) do
    case profile_photo_visibility(target_id) do
      "everyone" -> true
      "contacts" -> shares_conversation?(caller_id, target_id)
      _ -> false
    end
  end

  defp profile_photo_visibility(target_id) when is_binary(target_id) do
    case SharedInfra.UserClient.get_privacy(%{"user_id" => target_id}) do
      {:ok, privacy} ->
        Map.get(privacy, :profile_photo_visibility) ||
          Map.get(privacy, "profile_photo_visibility")

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp profile_photo_visibility(_target_id), do: nil

  defp shares_conversation?(caller_id, target_id)
       when is_binary(caller_id) and is_binary(target_id) do
    case SharedInfra.ConversationClient.shares_conversation?(%{
           "user_a" => caller_id,
           "user_b" => target_id
         }) do
      {:ok, result} -> SharedInfra.Attrs.get(result, :shares) == true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp shares_conversation?(_caller_id, _target_id), do: false

  defp either_blocked?(caller_id, target_id)
       when is_binary(caller_id) and is_binary(target_id) do
    case SharedInfra.ConversationClient.either_blocked?(%{
           "user_a" => caller_id,
           "user_b" => target_id
         }) do
      {:ok, %{blocked: true}} -> true
      {:ok, %{"blocked" => true}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp either_blocked?(_caller_id, _target_id), do: false
end
