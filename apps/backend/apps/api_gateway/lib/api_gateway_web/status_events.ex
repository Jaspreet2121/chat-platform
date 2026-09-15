defmodule ApiGatewayWeb.StatusEvents do
  @moduledoc """
  Live notice that someone's status changed, on the USER topic of everyone who may see it.

  THE GAP THIS CLOSES: a status post or delete was invisible to other clients until they refreshed
  the tab — nothing on the socket said "the feed changed". `status_updated` {user_id, status_id,
  action} on each recipient's `user:<id>` topic replaces that wait; recipients refetch the feed.

  WHO RECEIVES IT: exactly the post's audience — the message service answers
  `MessageClient.status_audience/1` with the SAME predicate the feed, the per-owner list and the
  media authz use (predating shared conversation, no block either way, the owner's audience mode).
  NEVER `peers_of/1`: that is "everyone who shares a conversation", which is wider than the audience
  — a blocked contact, a late joiner or an 'only'-mode outsider would learn a post exists.

  NEVER to the actor: their own devices already have the response to the request they just made.
  The audience query never returns the owner, and the filter here is kept anyway — it is
  load-bearing, not defensive.

  AFTER COMMIT, synchronously: this runs after the message client has returned the committed
  post/tombstone, costs one query plus N local PubSub broadcasts, and is wrapped so a failure here
  can never fail the request that triggered it.

  ACTIONS: "posted", "deleted". "expired" is part of the payload contract but is NOT emitted this
  slice: expiry is filter-at-read (`expires_at > now()`) with no server-side moment — the sweep runs
  an hour or more after expiry and only reclaims bytes. Clients already hide by `expires_at`.
  """

  require Logger

  @event "status_updated"

  @doc "Emit `status_updated` for `status_id` (owned by `actor_id`) with `action` to its audience."
  def emit(actor_id, status_id, action)
      when is_binary(actor_id) and actor_id != "" and is_binary(status_id) and status_id != "" and
             action in ["posted", "deleted", "expired"] do
    # EVERY OUTCOME NAMES ITSELF (the user_updated rule): emitted with a count, an empty audience
    # at info, and a failed lookup at warning with the reason — never the same line for two of them.
    case audience_of(actor_id, status_id) do
      {:ok, user_ids} ->
        recipients = user_ids |> Enum.reject(&(&1 == actor_id)) |> Enum.uniq()

        if recipients == [] do
          Logger.info(
            "status_updated skipped user=#{actor_id} status=#{status_id} reason=no_audience"
          )
        else
          payload = %{user_id: actor_id, status_id: status_id, action: action}

          Enum.each(
            recipients,
            &ApiGatewayWeb.Endpoint.broadcast("user:" <> &1, @event, payload)
          )

          Logger.info(
            "status_updated emitted user=#{actor_id} status=#{status_id} " <>
              "recipients=#{length(recipients)} action=#{action}"
          )
        end

      {:error, reason} ->
        Logger.warning(
          "status_updated failed user=#{actor_id} status=#{status_id} action=#{action}: " <>
            inspect(reason)
        )
    end

    :ok
  rescue
    error ->
      Logger.warning(
        "status_updated failed user=#{actor_id} status=#{status_id} action=#{action}: " <>
          inspect(error)
      )

      :ok
  end

  def emit(_actor_id, _status_id, _action), do: :ok

  # {:ok, ids} | {:error, reason} — never a bare list for both (a failed lookup must not read as
  # an empty audience).
  defp audience_of(actor_id, status_id) do
    case SharedInfra.MessageClient.status_audience(%{
           "owner_user_id" => actor_id,
           "status_id" => status_id
         }) do
      {:ok, result} ->
        case Map.get(result, :user_ids) || Map.get(result, "user_ids") do
          ids when is_list(ids) -> {:ok, ids}
          other -> {:error, {:malformed_reply, other}}
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_reply, other}}
    end
  end
end
