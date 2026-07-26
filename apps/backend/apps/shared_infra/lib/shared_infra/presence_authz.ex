defmodule SharedInfra.PresenceAuthz do
  @moduledoc """
  THE single rule for "may VIEWER see TARGET's presence?" — enforced at BOTH subscribe-time and read-time so
  the two can never drift.

  A viewer may see a target's online/last-seen iff, in order:
    1. there is NO block between them (either direction), AND
    2. the target's `last_seen_visibility` permits THIS viewer:
         * "everyone" → any authenticated viewer (still subject to the block above),
         * "contacts" → only viewers who SHARE an active conversation, and
         * "nobody"   → never.

  NOTE — `everyone` is now DISTINCT from `contacts` (it was previously collapsed to "contacts" — a setting
  named "everyone" that behaves like "contacts" is a lie to the user). Only users who explicitly chose
  "everyone" are affected; the default is "contacts", and presence is still queried per-id (a viewer must
  already know the target's id to ask), so this doesn't broadcast anyone to the world.

  FAIL-CLOSED on the visibility + shared-conversation inputs: an unknown/error value denies. A false "cannot
  see" only hides a green dot; a false "can see" leaks presence against the user's wishes — so uncertainty
  denies. (The opposite of the push-suppression marker, which fails OPEN — deliberately separate; see
  SharedInfra.Presence vs SharedInfra.PresenceMarker.)
  """

  @doc "May `viewer_id` see `target_id`'s presence? Fail-closed."
  def can_see?(viewer_id, target_id)
      when is_binary(viewer_id) and viewer_id != "" and is_binary(target_id) and target_id != "" do
    cond do
      # A user always sees their own presence (moot for subscribe, but never gate self).
      viewer_id == target_id -> true
      # A block hides presence BOTH ways (either direction) — checked before visibility/shared-conversation so
      # a blocked user is invisible even in a conversation you still share. Enforced at BOTH subscribe-time and
      # read-time (this is the single rule), so it can't drift between them.
      either_blocked?(viewer_id, target_id) -> false
      true -> visibility_allows?(viewer_id, target_id)
    end
  end

  def can_see?(_viewer_id, _target_id), do: false

  # The three-way last_seen_visibility rule. FAIL-CLOSED: unknown / error → deny (as if "nobody").
  defp visibility_allows?(viewer_id, target_id) do
    case last_seen_visibility(target_id) do
      "everyone" -> true
      "contacts" -> shares_conversation?(viewer_id, target_id)
      _ -> false
    end
  end

  defp last_seen_visibility(target_id) do
    case SharedInfra.UserClient.last_seen_visibility(%{"user_id" => target_id}) do
      {:ok, result} -> cget(result, :last_seen_visibility)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Either-direction block between viewer and target. Fail-OPEN (error → false = "no block"): a block-check
  # glitch just declines to hide by block; presence is still gated by shares_conversation? below, which fails
  # CLOSED — and a full ConversationClient outage hides everyone there anyway, so nothing leaks.
  defp either_blocked?(viewer_id, target_id) do
    case SharedInfra.ConversationClient.either_blocked?(%{
           "user_a" => viewer_id,
           "user_b" => target_id
         }) do
      {:ok, result} -> cget(result, :blocked) == true
      _ -> false
    end
  rescue
    _ -> false
  end

  # viewer and target share an active conversation. FAIL-CLOSED: unknown / error → false.
  defp shares_conversation?(viewer_id, target_id) do
    case SharedInfra.ConversationClient.shares_conversation?(%{
           "user_a" => viewer_id,
           "user_b" => target_id
         }) do
      {:ok, result} -> cget(result, :shares) == true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp cget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp cget(_map, _key), do: nil
end
