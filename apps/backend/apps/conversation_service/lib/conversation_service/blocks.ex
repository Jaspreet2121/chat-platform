defmodule ConversationService.Blocks do
  @moduledoc """
  User blocking — the DIRECTIONAL blocker→blocked relationship (`user_blocks`, migration 075) behind every
  block enforcement point.

  Owned here (not auth-service) because the HOTTEST check — the per-message send gate
  (`Participants.authorize_send`) — already runs in conversation-service, so co-locating the block data keeps
  that check a LOCAL indexed query with no cross-service round-trip and no cache. Cross-service callers
  (calls/presence/profile/endpoints in realtime-gateway + the gateway, which have no Repo) reach these through
  `SharedInfra.ConversationClient`.

  `either_blocked?/1` is the symmetric hot-path predicate: a block severs the 1-on-1 channel BOTH ways, which
  is coherent and can't be probed to reveal which side blocked whom. The directional `blocked?/1` is kept for
  completeness. Every READ FAILS OPEN on a malformed id / persistence-off / transient error (mirrors
  `authorize_send`): a check glitch must never wrongly deliver-block a legitimate action. Presence is the one
  deliberate exception — it fails CLOSED, in `SharedInfra.PresenceAuthz`.
  """

  require Logger

  alias ConversationService.Repo

  @doc """
  Block `blocked_user_id` on behalf of `blocker_user_id`. Idempotent (a re-block is a no-op via the PK's
  ON CONFLICT). Self-block → `:block_self`. An unknown blocked user (no `users_auth` row) trips the FK →
  `:block_unknown_user` (the endpoint maps it to 404, no existence leak beyond what by-phone reveals).
  """
  def block(attrs) do
    with {:ok, blocker} <- required(attrs, "blocker_user_id"),
         {:ok, blocked} <- required(attrs, "blocked_user_id"),
         :ok <- refute_self(blocker, blocked),
         {:ok, b} <- dump(blocker),
         {:ok, t} <- dump(blocked) do
      Repo.query!(
        "INSERT INTO user_blocks (blocker_user_id, blocked_user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
        [b, t]
      )

      {:ok, %{blocker_user_id: blocker, blocked_user_id: blocked}}
    end
  rescue
    # FK violation (blocked_user_id isn't a real account) → not-found, never a 500.
    Postgrex.Error -> {:error, :block_unknown_user}
  end

  @doc "Remove a block. Idempotent (deleting a non-existent block is still `:ok`)."
  def unblock(attrs) do
    with {:ok, blocker} <- required(attrs, "blocker_user_id"),
         {:ok, blocked} <- required(attrs, "blocked_user_id"),
         {:ok, b} <- dump(blocker),
         {:ok, t} <- dump(blocked) do
      Repo.query!(
        "DELETE FROM user_blocks WHERE blocker_user_id = $1 AND blocked_user_id = $2",
        [b, t]
      )

      {:ok, %{blocker_user_id: blocker, blocked_user_id: blocked}}
    end
  rescue
    Postgrex.Error -> {:error, :block_invalid}
  end

  @doc "Does `blocker_user_id` block `blocked_user_id`? (directional). Fail-open → false."
  def blocked?(attrs) do
    with_persistence(fn ->
      with {:ok, blocker} <- required(attrs, "blocker_user_id"),
           {:ok, blocked} <- required(attrs, "blocked_user_id"),
           {:ok, b} <- dump(blocker),
           {:ok, t} <- dump(blocked) do
        %Postgrex.Result{rows: [[exists]]} =
          Repo.query!(
            "SELECT EXISTS (SELECT 1 FROM user_blocks WHERE blocker_user_id = $1 AND blocked_user_id = $2)",
            [b, t]
          )

        {:ok, %{blocked: exists}}
      else
        _ -> {:ok, %{blocked: false}}
      end
    end)
  end

  @doc """
  Is there a block in EITHER direction between `user_a` and `user_b`? The symmetric hot-path check used by
  messages, calls, presence, and profile. Fail-open → false (never deliver-block a legitimate action on a
  check glitch).
  """
  def either_blocked?(attrs) do
    with_persistence(fn ->
      with {:ok, a} <- required(attrs, "user_a"),
           {:ok, b} <- required(attrs, "user_b"),
           {:ok, ua} <- dump(a),
           {:ok, ub} <- dump(b) do
        %Postgrex.Result{rows: [[exists]]} =
          Repo.query!(
            """
            SELECT EXISTS (
              SELECT 1 FROM user_blocks
              WHERE (blocker_user_id = $1 AND blocked_user_id = $2)
                 OR (blocker_user_id = $2 AND blocked_user_id = $1)
            )
            """,
            [ua, ub]
          )

        {:ok, %{blocked: exists}}
      else
        _ -> {:ok, %{blocked: false}}
      end
    end)
  end

  @doc """
  Is `user_id`'s DIRECT peer in `conversation_id` blocked (either direction)? True ONLY when the conversation
  is `direct`, `user_id` is an active member, and there's an either-direction block with the other member.
  Groups always return false — blocking is 1-on-1, and a blocked member may still post to a shared group.
  Fail-open → false. Backs the message drop (called locally by `authorize_send`) and the typing/viewing gate.
  """
  def direct_peer_blocked?(attrs) do
    with_persistence(fn ->
      with {:ok, conversation_id} <- required(attrs, "conversation_id"),
           {:ok, user_id} <- required(attrs, "user_id"),
           {:ok, cid} <- dump(conversation_id),
           {:ok, uid} <- dump(user_id) do
        %Postgrex.Result{rows: [[blocked]]} =
          Repo.query!(
            """
            SELECT EXISTS (
              SELECT 1
              FROM conversations c
              JOIN conversation_participants me
                ON me.conversation_id = c.id AND me.user_id = $2 AND me.left_at IS NULL
              JOIN conversation_participants peer
                ON peer.conversation_id = c.id AND peer.user_id <> $2 AND peer.left_at IS NULL
              JOIN user_blocks ub
                ON (ub.blocker_user_id = $2 AND ub.blocked_user_id = peer.user_id)
                OR (ub.blocker_user_id = peer.user_id AND ub.blocked_user_id = $2)
              WHERE c.id = $1 AND c.type = 'direct'
            )
            """,
            [cid, uid]
          )

        {:ok, %{blocked: blocked}}
      else
        _ -> {:ok, %{blocked: false}}
      end
    end)
  end

  @doc "The list of users `blocker_user_id` has blocked (newest first): `[%{user_id, created_at}]`."
  def list_blocks(attrs) do
    with_persistence(
      fn ->
        with {:ok, blocker} <- required(attrs, "blocker_user_id"),
             {:ok, b} <- dump(blocker) do
          %Postgrex.Result{rows: rows} =
            Repo.query!(
              "SELECT blocked_user_id::text, to_char(created_at, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') " <>
                "FROM user_blocks WHERE blocker_user_id = $1 ORDER BY created_at DESC",
              [b]
            )

          {:ok, %{blocks: Enum.map(rows, fn [uid, created_at] -> %{user_id: uid, created_at: created_at} end)}}
        else
          _ -> {:ok, %{blocks: []}}
        end
      end,
      {:ok, %{blocks: []}}
    )
  end

  # --- helpers ---

  # Persistence off (no DB — the Docker-free default) → the fallback (no blocks). A block is only ever real
  # against the shared Postgres, so this is correct, not a stub.
  defp with_persistence(fun, fallback \\ {:ok, %{blocked: false}}) do
    if persistence_enabled?(), do: fun.(), else: fallback
  rescue
    error ->
      Logger.warning("blocks check failed, failing open: #{inspect(error)}")
      fallback
  end

  defp persistence_enabled? do
    Application.get_env(:conversation_service, :conversation_persistence, false) ||
      System.get_env("CONVERSATION_DB_BACKED") in ["true", "1", "yes"]
  end

  defp required(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, safe_atom(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :block_invalid}
    end
  end

  defp refute_self(blocker, blocked) do
    if blocker == blocked, do: {:error, :block_self}, else: :ok
  end

  defp dump(id) do
    case Ecto.UUID.dump(id) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :block_invalid}
    end
  end

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :__missing__
  end
end
