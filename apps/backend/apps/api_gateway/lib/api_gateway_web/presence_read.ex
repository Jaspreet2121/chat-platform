defmodule ApiGatewayWeb.PresenceRead do
  @moduledoc """
  The presence SNAPSHOT read, shared by the `/v1` and first-party controllers so the privacy rule can't drift
  between them. Given a caller and a list of target user ids, returns one entry per target:

      %{user_id: t, online: boolean, last_seen_at: iso8601 | nil}

  Privacy is enforced PER TARGET via `SharedInfra.PresenceAuthz.can_see?/2` (a shared conversation AND the
  target's visibility permits). FAIL-CLOSED on the DISPLAY side: a target the caller may not see — or any
  error resolving that — is reported as simply OFFLINE (`online: false, last_seen_at: nil`), indistinguishable
  from a genuinely-offline user. So a hidden user never looks reachable, and the caller can't tell "hidden"
  from "offline" (which is the point). Online users report no last_seen (they're here now).
  """

  alias SharedInfra.Presence
  alias SharedInfra.PresenceAuthz

  @max_targets 200

  @doc "Privacy-filtered presence for `target_ids` as seen by `caller_id`. Caps at #{@max_targets} targets."
  def snapshot(caller_id, target_ids) when is_binary(caller_id) and is_list(target_ids) do
    target_ids
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.take(@max_targets)
    |> Enum.map(&entry(caller_id, &1))
  end

  def snapshot(_caller_id, _targets), do: []

  defp entry(caller_id, target) do
    if PresenceAuthz.can_see?(caller_id, target) do
      online = Presence.online?(target)
      # A live user reports no last_seen (they're online now); an offline one reports their last disconnect.
      last_seen = if online, do: nil, else: Presence.last_seen(target)
      %{user_id: target, online: online, last_seen_at: iso8601(last_seen)}
    else
      # Not permitted (or unresolvable) → fail-closed to "offline", never a phantom online or a leak.
      %{user_id: target, online: false, last_seen_at: nil}
    end
  end

  defp iso8601(nil), do: nil
  defp iso8601(unix) when is_integer(unix), do: unix |> DateTime.from_unix!() |> DateTime.to_iso8601()

  @doc "Parse a `user_ids` query value: a comma-separated string or a repeated-param list → [id]."
  def parse_ids(value) when is_binary(value), do: value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  def parse_ids(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  def parse_ids(_), do: []
end
