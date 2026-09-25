defmodule ConversationService.MessageRequests do
  @moduledoc """
  MESSAGE REQUESTS (128) — a first DM from a STRANGER waits in a separate bucket until the recipient
  accepts it.

  State is ONE nullable timestamp on the RECIPIENT's own `conversation_participants` row,
  `request_pending_at`, exactly the shape `archived_at` (076) uses for "exists but not in the main
  list". The SENDER's row is never stamped: their side is a normal conversation from the moment they
  send, which is what makes "the sender sees delivered exactly as today" true without a second code
  path anywhere.

  ## Who is a stranger

  Three signals, all server-side, ALL of which must be absent:

    * no prior shared ACTIVE conversation, direct or group;
    * no `nearby_connections` row for the pair (an accepted nearby request);
    * no `dating_matches` row for the pair (a mutual like).

  CONTACTS ARE DELIBERATELY NOT A SIGNAL. `POST /api/v1/contacts/sync` is stateless by design and
  persists nothing, so the server cannot answer "is B in A's address book" at any price and will not
  start storing a social graph to find out. A client that knows its own address book may badge a
  request as "in your contacts"; the server's bucket does not move.

  ## The recursion the predicate has to avoid

  A PENDING row must not itself count as a shared conversation. If it did, the second message from
  the same stranger would find them "already connected" and walk straight past the gate, and the
  first request would silently promote every later one. `shared_active_conversation?/3` therefore
  requires BOTH sides' participant rows to have a NULL `request_pending_at`, and excludes the
  conversation being created.

  That same rule is why the presence, status-audience and profile-visibility predicates were widened
  in this slice rather than a later one: each of them asks "do these two share a conversation?", and
  each would have been answered "yes" by an unaccepted request.
  """

  require Logger

  alias ConversationService.Repo

  @doc """
  Is `user_b` a stranger to `user_a`? `exclude_conversation_id` is the conversation being created,
  whose freshly-inserted participant rows must not answer their own question.

  ONE query, at conversation-creation time only — never per message. A wrong answer here fails OPEN
  (not a stranger, so no request bucket): a Postgres hiccup must not silently divert a legitimate
  first message from a real contact into a bucket the recipient may never look at. The cost of
  failing open is one un-bucketed message from a stranger; the cost of failing closed is a real
  conversation disappearing.
  """
  def stranger?(user_a, user_b, exclude_conversation_id) do
    with {:ok, a} <- dump(user_a),
         {:ok, b} <- dump(user_b),
         {:ok, excluded} <- dump(exclude_conversation_id) do
      %Postgrex.Result{rows: [[connected]]} =
        Repo.query!(
          """
          SELECT (
            EXISTS (
              SELECT 1
              FROM conversation_participants pa
              JOIN conversation_participants pb ON pb.conversation_id = pa.conversation_id
              JOIN conversations c ON c.id = pa.conversation_id AND c.status = 'active'
              WHERE pa.user_id = $1 AND pa.left_at IS NULL AND pa.request_pending_at IS NULL
                AND pb.user_id = $2 AND pb.left_at IS NULL AND pb.request_pending_at IS NULL
                AND pa.conversation_id <> $3
            )
            OR EXISTS (
              SELECT 1 FROM nearby_connections
              WHERE user_low_id = LEAST($1, $2) AND user_high_id = GREATEST($1, $2)
            )
            OR EXISTS (
              SELECT 1 FROM dating_matches
              WHERE user_low_id = LEAST($1, $2) AND user_high_id = GREATEST($1, $2)
                AND unmatched_at IS NULL
            )
          )
          """,
          [a, b, excluded]
        )

      not connected
    else
      _ -> false
    end
  rescue
    error ->
      Logger.warning(
        "message request stranger check failed, treating as known: #{inspect(error)}"
      )

      false
  end

  @doc """
  Stamp the RECIPIENT's participant row pending, if they are a stranger to the creator.

  Called INSIDE the conversation-creation transaction, so a row is never briefly visible as accepted.
  DIRECT conversations with exactly two participants only: a group has no single "recipient", and the
  group-invite path has its own membership rules.

  Returns `:ok` either way — whether a chat is bucketed is a product decision, not a correctness one,
  and it must never roll back the conversation.
  """
  def maybe_stamp_recipient(%{type: "direct", id: conversation_id}, created_by, [_, _] = user_ids) do
    case Enum.reject(user_ids, &(to_string(&1) == to_string(created_by))) do
      [recipient] ->
        if stranger?(created_by, recipient, conversation_id) do
          stamp(conversation_id, recipient)
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  def maybe_stamp_recipient(_conversation, _created_by, _user_ids), do: :ok

  defp stamp(conversation_id, recipient) do
    with {:ok, cid} <- dump(conversation_id), {:ok, uid} <- dump(recipient) do
      Repo.query!(
        "UPDATE conversation_participants SET request_pending_at = now() " <>
          "WHERE conversation_id = $1 AND user_id = $2 AND request_pending_at IS NULL",
        [cid, uid]
      )

      Logger.info("message request opened conversation=#{conversation_id}")
      :ok
    else
      _ -> :ok
    end
  end

  @doc """
  ACCEPT: clear the pending flag on the caller's own row. The chat joins their normal inbox, pushes
  resume, and the pair now counts as a shared conversation everywhere.

  The caller's own user id IS the authorization — it is in the WHERE clause, so a non-recipient
  matches zero rows and gets `:request_not_found`, the same answer as an id that never existed. Only
  a row that is actually pending can be accepted, which makes a double-accept idempotent-looking
  rather than a silent no-op on someone else's row.
  """
  def accept(attrs) do
    respond(attrs, :accept)
  end

  @doc """
  DECLINE: clear the pending flag AND block the sender, in ONE transaction.

  SILENT, mirroring the nearby decline: nothing is broadcast, nothing is pushed, and the sender's
  later messages are dropped by the existing block path, where they still see a single tick. A
  decline that told the sender it had happened would make declining risky for the recipient, which is
  the opposite of the point.

  The flag is CLEARED rather than left set, because the block is now the durable state; leaving a
  pending row behind would keep the chat in a requests bucket the recipient has finished with.

  AND THE ROW IS ARCHIVED, which is a judgement this slice makes rather than one it was handed.
  Clearing the flag alone would move the declined chat out of the requests bucket and straight into
  the decliner's MAIN inbox, since the inbox query does not filter blocks — the precise leak this
  feature exists to prevent, arriving through the decline path. Archiving is the mechanism that
  already means "exists, but not in my main list" (076), it is reversible by the user, and it deletes
  nothing. The block is what stops the sender; the archive is what stops the chat from reappearing.
  """
  def decline(attrs) do
    respond(attrs, :decline)
  end

  defp respond(attrs, decision) do
    with {:ok, conversation_id} <- required(attrs, "conversation_id"),
         {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, cid} <- dump(conversation_id),
         {:ok, uid} <- dump(user_id) do
      Repo.transaction(fn ->
        %Postgrex.Result{num_rows: cleared} =
          Repo.query!(
            "UPDATE conversation_participants SET request_pending_at = NULL " <>
              "WHERE conversation_id = $1 AND user_id = $2 AND request_pending_at IS NOT NULL",
            [cid, uid]
          )

        if cleared == 0 do
          Repo.rollback(:request_not_found)
        else
          if decision == :decline do
            block_peer(cid, uid)
            archive_for(cid, uid)
          end

          %{conversation_id: conversation_id, status: to_string(decision) <> "ed"}
        end
      end)
    else
      _ -> {:error, :request_invalid}
    end
  rescue
    Postgrex.Error -> {:error, :request_invalid}
  end

  # The other side of a DIRECT conversation, blocked by the decliner. Inside the same transaction as
  # the clear: a decline that cleared the flag but failed to block would leave the sender able to keep
  # writing into a chat the recipient believes they have refused.
  defp block_peer(conversation_uuid, decliner_uuid) do
    Repo.query!(
      """
      INSERT INTO user_blocks (blocker_user_id, blocked_user_id)
      SELECT $2, peer.user_id
      FROM conversation_participants peer
      JOIN conversations c ON c.id = peer.conversation_id AND c.type = 'direct'
      WHERE peer.conversation_id = $1 AND peer.user_id <> $2
      ON CONFLICT DO NOTHING
      """,
      [conversation_uuid, decliner_uuid]
    )

    :ok
  end

  # Set the decliner's OWN archive flag, so the declined chat leaves the main list instead of joining
  # it. Their own row only: archiving is a per-user inbox preference and the sender's side is
  # untouched, which is what keeps the decline invisible to them.
  defp archive_for(conversation_uuid, decliner_uuid) do
    Repo.query!(
      "UPDATE conversation_participants SET archived_at = now() " <>
        "WHERE conversation_id = $1 AND user_id = $2 AND archived_at IS NULL",
      [conversation_uuid, decliner_uuid]
    )

    :ok
  end

  @doc """
  Is this participant's row an UNACCEPTED request? The per-message read used by the send budget and
  by the notification gate. One primary-key probe on `(conversation_id, user_id)`.
  """
  def pending?(conversation_id, user_id) do
    with {:ok, cid} <- dump(conversation_id), {:ok, uid} <- dump(user_id) do
      %Postgrex.Result{rows: [[pending]]} =
        Repo.query!(
          "SELECT EXISTS (SELECT 1 FROM conversation_participants " <>
            "WHERE conversation_id = $1 AND user_id = $2 AND request_pending_at IS NOT NULL)",
          [cid, uid]
        )

      pending
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Does this DIRECT conversation have an unaccepted request on EITHER side? The form the send path
  needs: it knows the conversation, not which participant is waiting.

  Returns `{:ok, %{pending: boolean, direct_key: binary | nil}}`. `direct_key` rides along because
  the caller's next step is a per-PAIR rate-limit key and it is already in this row — fetching it
  here costs nothing and saves the send path a second query.
  """
  def request_state(attrs) do
    with {:ok, conversation_id} <- required(attrs, "conversation_id"),
         {:ok, cid} <- dump(conversation_id) do
      %Postgrex.Result{rows: rows} =
        Repo.query!(
          """
          SELECT c.direct_key,
                 EXISTS (SELECT 1 FROM conversation_participants p
                         WHERE p.conversation_id = c.id AND p.request_pending_at IS NOT NULL)
          FROM conversations c
          WHERE c.id = $1 AND c.type = 'direct'
          """,
          [cid]
        )

      case rows do
        [[direct_key, pending]] -> {:ok, %{pending: pending, direct_key: direct_key}}
        _ -> {:ok, %{pending: false, direct_key: nil}}
      end
    else
      _ -> {:ok, %{pending: false, direct_key: nil}}
    end
  rescue
    _ -> {:ok, %{pending: false, direct_key: nil}}
  end

  defp required(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, String.to_existing_atom(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp dump(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, binary} -> {:ok, binary}
      :error -> :error
    end
  end

  defp dump(_value), do: :error
end
