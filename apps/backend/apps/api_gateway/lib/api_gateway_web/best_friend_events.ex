defmodule ApiGatewayWeb.BestFriendEvents do
  @moduledoc """
  `best_friend_mutual` — the live notice that two people have pinned EACH OTHER (125).

  A best-friend pin is private until it is returned. One side pinning tells the other nothing (the
  inbox row carries only the CALLER's own `best_friend` flag); the moment both sides have pinned,
  both are told at once, because that is the fact that is now true of the pair rather than of one
  person. Unpinning emits `mutual: false` to the same two people, so a client that lit up does not
  stay lit.

  ## Who receives it

  ONLY the DM's two members — the ids the conversation service returned with the pin it just wrote,
  which come from the participant rows themselves. There is no path here that broadcasts to a topic
  derived from client input, so a non-member cannot be a recipient.

  ## Ordering

  AFTER the commit, synchronously — the pin has been written and read back as mutual before anything
  is emitted. A client that receives this and immediately refetches must not race the write it was
  told about. Wrapped so a PubSub failure can never fail the pin.
  """

  require Logger

  @event "best_friend_mutual"

  @doc """
  Emit to both members of `conversation_id`. `mutual` is what the write itself resolved to — this
  function never recomputes it, so the frame can only ever say what the database said.
  """
  def emit(conversation_id, member_ids, mutual)
      when is_binary(conversation_id) and is_list(member_ids) and is_boolean(mutual) do
    recipients = Enum.filter(member_ids, &(is_binary(&1) and &1 != ""))

    if recipients == [] do
      Logger.info("best_friend_mutual skipped conversation=#{conversation_id} reason=no_members")
    else
      payload = %{conversation_id: conversation_id, mutual: mutual}

      Enum.each(
        recipients,
        &ApiGatewayWeb.Endpoint.broadcast("user:" <> &1, @event, payload)
      )

      for user_id <- recipients do
        Logger.info(
          "best_friend_mutual emitted user=#{user_id} conversation=#{conversation_id} mutual=#{mutual}"
        )
      end
    end

    :ok
  rescue
    error ->
      Logger.warning(
        "best_friend_mutual failed conversation=#{conversation_id}: #{inspect(error)}"
      )

      :ok
  end

  def emit(_conversation_id, _member_ids, _mutual), do: :ok
end
