defmodule ApiGatewayWeb.UserEvents do
  @moduledoc """
  Live notice that a user's own profile changed, on the USER topic.

  THE GAP THIS CLOSES: a peer's avatar is keyed on `avatar_media_id` and read off their card, and
  nothing told anyone when that id changed — so B kept drawing A's old picture until B's next card
  fetch, up to an hour later. One event at change time replaces that wait.

  AVATAR ONLY, this slice. Name and bio are not emitted: they are re-read on the same card fetch and
  nobody is caching them by id, so an event for them would be noise with a fan-out cost.
  """

  require Logger

  @doc """
  Tell everyone who shares a conversation with `actor_id` that their avatar changed.

  SYNCHRONOUS, on purpose. The contract is "never before the commit", and a spawned task cannot
  promise that — it promises only "eventually, in some order". This runs after the store has
  returned, costs one query plus N local PubSub broadcasts, and is wrapped so that a failure here
  can never fail the profile save that triggered it.

  `avatar_media_id` is nil when the photo was CLEARED — the recipient needs that just as much as a
  new id, and an event that only fired on "set" would leave a removed photo on screen forever.
  """
  def avatar_changed(actor_id, avatar_media_id)
      when is_binary(actor_id) and actor_id != "" do
    # EVERY OUTCOME NAMES ITSELF. This used to log nothing on success and nothing on an empty
    # recipient set, and swallowed a failed peer lookup into that same empty set — so "the event
    # never reached the phone" could not be told apart from "nobody was there to receive it" or
    # "the conversation service was down", and an inspection was spent proving the emit worked.
    # The same silent-success class as FcmSender before 60b84d2, shipped two commits after fixing it.
    case peers_of(actor_id) do
      {:ok, peer_ids} ->
        # NEVER to the actor: their own devices already have the response to the request they just
        # made, and echoing it back would make every listening client re-fetch its own card for
        # nothing. A self-DM puts the actor in the peer set, so this filter is load-bearing.
        recipients = Enum.reject(peer_ids, &(&1 == actor_id))

        if recipients == [] do
          Logger.info("user_updated skipped user=#{actor_id} reason=no_peers")
        else
          payload = %{user_id: actor_id, avatar_media_id: avatar_media_id}

          Enum.each(
            recipients,
            &ApiGatewayWeb.Endpoint.broadcast("user:" <> &1, "user_updated", payload)
          )

          Logger.info("user_updated emitted user=#{actor_id} recipients=#{length(recipients)}")
        end

      {:error, reason} ->
        # DISTINCT from no_peers on purpose: an outage of the conversation service and a user with
        # no conversations must not read as the same line.
        Logger.warning("user_updated failed user=#{actor_id}: #{inspect(reason)}")
    end

    :ok
  rescue
    error ->
      Logger.warning("user_updated failed user=#{actor_id}: #{inspect(error)}")
      :ok
  end

  def avatar_changed(_actor_id, _avatar_media_id), do: :ok

  # {:ok, ids} | {:error, reason} — NEVER a bare list for both. The previous catch-all (`_ -> []`)
  # is exactly how a failed lookup became indistinguishable from an empty one.
  defp peers_of(actor_id) do
    case SharedInfra.ConversationClient.peers_of(%{"user_id" => actor_id}) do
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
