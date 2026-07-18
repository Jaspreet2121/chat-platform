defmodule SharedInfra.PresenceAuthz do
  @moduledoc """
  THE single rule for "may VIEWER see TARGET's presence?" — enforced at BOTH subscribe-time and read-time so
  the two can never drift.

  A viewer may see a target's online/last-seen iff:
    1. the target's `last_seen_visibility` is NOT "nobody", AND
    2. they SHARE an active conversation (the "contacts" relation).

  Per the product decision, "everyone" and "contacts" behave identically — presence is only ever visible to
  people you share a conversation with; visibility only decides whether even THAT is allowed (`nobody` = never).
  So the rule collapses to `visibility != "nobody" AND shares_conversation?`.

  FAIL-CLOSED on both inputs: if the visibility read OR the shared-conversation check errors or is unknown, the
  answer is NO. A false "cannot see" only hides a green dot; a false "can see" leaks presence against the
  user's wishes — so uncertainty denies. (This is the opposite of the push-suppression marker, which fails
  OPEN — the two are deliberately separate; see SharedInfra.Presence vs SharedInfra.PresenceMarker.)
  """

  @doc "May `viewer_id` see `target_id`'s presence? Fail-closed."
  def can_see?(viewer_id, target_id)
      when is_binary(viewer_id) and viewer_id != "" and is_binary(target_id) and target_id != "" do
    cond do
      # A user always sees their own presence (moot for subscribe, but never gate self).
      viewer_id == target_id -> true
      not visible?(target_id) -> false
      true -> shares_conversation?(viewer_id, target_id)
    end
  end

  def can_see?(_viewer_id, _target_id), do: false

  # target's last_seen_visibility != "nobody". FAIL-CLOSED: unknown / error → treat as "nobody" (deny).
  defp visible?(target_id) do
    case SharedInfra.UserClient.last_seen_visibility(%{"user_id" => target_id}) do
      {:ok, result} ->
        case cget(result, :last_seen_visibility) do
          "nobody" -> false
          v when is_binary(v) and v != "" -> true
          _ -> false
        end

      _ ->
        false
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
