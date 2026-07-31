defmodule MessageService.Statuses do
  @moduledoc """
  STATUS (Stories), commit 1 (082): ephemeral posts (text | image | video), 24h expiry by
  FILTER-AT-READ, media bytes reclaimed by a WRITE-AMORTISED sweep, and the contacts audience with the
  PREDATING rule.

  THE AUDIENCE PREDICATE (one implementation — `audience_sql/0` — consumed by the feed, the per-owner
  list, AND the media-authz check, so the three can never drift):

      visible(owner → viewer) =
        EXISTS a shared ACTIVE conversation where BOTH participant rows PREDATE the post
          (owner.joined_at < post.created_at AND viewer.joined_at < post.created_at,
           both left_at IS NULL — leaving is a LIVE deny)
        AND NOT either_blocked?(owner, viewer)   (live, both directions)

  WHY joined_at (each side's own row), not the conversation's created_at: the surprise being closed is
  "my audience grew retroactively" — someone I meet TOMORROW seeing what I posted TODAY. A late joiner
  to a group the owner has sat in for years is exactly that stranger: the CONVERSATION predates the
  post, but the relationship through it does not. joined_at bounds the ALLOW side per person; every
  deny (blocks, leaving, expiry, delete) stays live. And the owner's own joined_at is checked too —
  the owner JOINING a big group after posting must not retroactively admit that group.

  Commit 1 honors mode 'contacts' only; 'except'/'only' (status_audience/members) land in commit 2.

  EXPIRY: every read carries `expires_at > now() AND deleted_at IS NULL`. THE SWEEP (write-amortised,
  no scheduler): each post drains ≤#{25} posts expired >1h ago — purge the media object (MediaClient)
  + stamp media_purged_at — and hard-deletes post+view rows >30 days old. Sweep rate ≥25× accrual rate
  ⇒ the backlog converges while the system is alive; owner-delete purges its object immediately.
  """

  require Logger

  alias MessageService.Repo

  @ttl_hours 24
  @sweep_batch 25
  @sweep_grace_seconds 3600
  @purge_rows_after_days 30
  @max_body 700
  @kinds ~w(text image video)

  # --- POST --------------------------------------------------------------------------------------

  @doc """
  Post a status. text → body required (≤#{700} chars), no media; image/video → media_id required
  (ownership/purpose enforced by the gateway upload + authz paths). → {:ok, canonical post}.
  Errors: :status_invalid_kind | :status_invalid_body | :status_media_required.
  """
  def post_status(attrs) do
    with :ok <- ensure_persistence(),
         {:ok, owner} <- required(attrs, "owner_user_id"),
         {:ok, kind} <- valid_kind(attrs),
         :ok <- valid_content(kind, attrs) do
      id = Ecto.UUID.generate()
      app_id = SharedInfra.Tenancy.app_id_or_default(get_attr(attrs, "app_id"))
      metadata = normalize_metadata(get_attr(attrs, "metadata"))

      %{rows: [[created_at, expires_at]]} =
        Repo.query!(
          "INSERT INTO status_posts (id, owner_user_id, app_id, kind, body, media_id, metadata, expires_at) " <>
            "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, $4, $5, $6::text::uuid, $7, now() + make_interval(hours => $8)) " <>
            "RETURNING to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"'), " <>
            "to_char(expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')",
          [id, owner, app_id, kind, get_attr(attrs, "body"), get_attr(attrs, "media_id"), metadata, @ttl_hours]
        )

      # The write-amortised sweep rides every post, off nothing critical (errors are logged, never raised).
      sweep()

      {:ok,
       %{
         status_id: id,
         owner_user_id: owner,
         kind: kind,
         body: get_attr(attrs, "body"),
         media_id: get_attr(attrs, "media_id"),
         metadata: metadata,
         created_at: created_at,
         expires_at: expires_at
       }}
    end
  rescue
    Ecto.Query.CastError -> {:error, :status_invalid}
  end

  # --- READ --------------------------------------------------------------------------------------

  # The ONE audience predicate (see moduledoc). Parameters: $1 = viewer, $2 = owner-column reference is
  # inlined by callers via sp (status_posts alias). Blocks are live + symmetric.
  defp audience_sql do
    """
    EXISTS (
      SELECT 1 FROM conversation_participants me
      JOIN conversation_participants them
        ON them.conversation_id = me.conversation_id
      JOIN conversations c ON c.id = me.conversation_id AND c.status = 'active'
      WHERE me.user_id = $1::uuid AND me.left_at IS NULL AND me.joined_at < sp.created_at
        AND them.user_id = sp.owner_user_id AND them.left_at IS NULL AND them.joined_at < sp.created_at
    )
    AND NOT EXISTS (
      SELECT 1 FROM user_blocks b
      WHERE (b.blocker_user_id = $1::uuid AND b.blocked_user_id = sp.owner_user_id)
         OR (b.blocker_user_id = sp.owner_user_id AND b.blocked_user_id = $1::uuid)
    )
    """
  end

  @doc """
  The status tab, ONE query: every owner with live posts visible to the viewer → one thread row.
  → {:ok, %{threads: [%{owner_user_id, post_count, latest_at, unseen_count}]}} (unseen from
  status_views — until commit 2 records views it equals post_count).
  """
  def feed(attrs) do
    with :ok <- ensure_persistence(),
         {:ok, viewer} <- required(attrs, "viewer_user_id") do
      %{rows: rows} =
        Repo.query!(
          "SELECT sp.owner_user_id::text, count(*)::int, " <>
            "to_char(max(sp.created_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"'), " <>
            "count(*) FILTER (WHERE v.viewer_user_id IS NULL)::int " <>
            "FROM status_posts sp " <>
            "LEFT JOIN status_views v ON v.status_id = sp.id AND v.viewer_user_id = $1::uuid " <>
            "WHERE sp.expires_at > now() AND sp.deleted_at IS NULL AND sp.owner_user_id <> $1::uuid " <>
            "AND " <> audience_sql() <>
            "GROUP BY sp.owner_user_id ORDER BY max(sp.created_at) DESC",
          [viewer]
        )

      threads =
        Enum.map(rows, fn [owner, count, latest, unseen] ->
          %{owner_user_id: owner, post_count: count, latest_at: latest, unseen_count: unseen}
        end)

      {:ok, %{threads: threads}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :status_invalid}
  end

  @doc """
  One owner's live posts as the viewer may see them (chronological). The owner reading their OWN posts
  bypasses the audience predicate (their recap — "my status"). Invisible owner ≡ no posts → empty list
  (no existence reveal). → {:ok, %{posts: [...]}}
  """
  def list_posts(attrs) do
    with :ok <- ensure_persistence(),
         {:ok, viewer} <- required(attrs, "viewer_user_id"),
         {:ok, owner} <- required(attrs, "owner_user_id") do
      %{rows: rows} =
        Repo.query!(
          "SELECT sp.id::text, sp.kind, sp.body, sp.media_id::text, sp.metadata, " <>
            "to_char(sp.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"'), " <>
            "to_char(sp.expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') " <>
            "FROM status_posts sp " <>
            "WHERE sp.owner_user_id = $2::uuid AND sp.expires_at > now() AND sp.deleted_at IS NULL " <>
            "AND (sp.owner_user_id = $1::uuid OR (" <> audience_sql() <> ")) " <>
            "ORDER BY sp.created_at ASC",
          [viewer, owner]
        )

      posts =
        Enum.map(rows, fn [id, kind, body, media_id, metadata, created_at, expires_at] ->
          %{
            status_id: id,
            owner_user_id: owner,
            kind: kind,
            body: body,
            media_id: media_id,
            metadata: metadata || %{},
            created_at: created_at,
            expires_at: expires_at
          }
        end)

      {:ok, %{posts: posts}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :status_invalid}
  end

  @doc """
  Media-authz support (the gateway's purpose-"status" arm): may `viewer` fetch the media behind this
  media_id? The owning post must be LIVE (expired/deleted → denied, even with the id in hand); the
  owner is always allowed; everyone else runs the SAME audience predicate as the feed.
  → {:ok, %{allowed: bool}}
  """
  def media_allowed(attrs) do
    with :ok <- ensure_persistence(),
         {:ok, viewer} <- required(attrs, "viewer_user_id"),
         {:ok, media_id} <- required(attrs, "media_id") do
      %{rows: rows} =
        Repo.query!(
          "SELECT (sp.owner_user_id = $1::uuid) OR (" <> audience_sql() <> ") " <>
            "FROM status_posts sp " <>
            "WHERE sp.media_id = $2::uuid AND sp.expires_at > now() AND sp.deleted_at IS NULL " <>
            "LIMIT 1",
          [viewer, media_id]
        )

      case rows do
        [[true]] -> {:ok, %{allowed: true}}
        _ -> {:ok, %{allowed: false}}
      end
    end
  rescue
    Ecto.Query.CastError -> {:ok, %{allowed: false}}
  end

  # --- DELETE ------------------------------------------------------------------------------------

  @doc "Owner-delete: tombstone the row + purge the media object immediately. Foreign/unknown → :status_not_found."
  def delete_status(attrs) do
    with :ok <- ensure_persistence(),
         {:ok, owner} <- required(attrs, "owner_user_id"),
         {:ok, status_id} <- required(attrs, "status_id") do
      %{rows: rows} =
        Repo.query!(
          "UPDATE status_posts SET deleted_at = now() " <>
            "WHERE id = $1::text::uuid AND owner_user_id = $2::text::uuid AND deleted_at IS NULL " <>
            "RETURNING media_id::text, app_id::text",
          [status_id, owner]
        )

      case rows do
        [[media_id, app_id]] ->
          purge_media(status_id, media_id, app_id)
          {:ok, %{deleted: true}}

        _ ->
          {:error, :status_not_found}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :status_not_found}
  end

  # --- THE SWEEP ---------------------------------------------------------------------------------

  @doc """
  The write-amortised cleanup (public so a future real scheduler can call it as-is): purge media for
  ≤#{25} posts expired >1h ago, then hard-delete post+view rows older than #{30} days. Fire-and-forget
  from post_status; errors log, never raise into the posting request.
  """
  def sweep do
    # Async by default (never on the posting request's critical path); tests run run_sweep/0 inline —
    # a spawned Task can't share the SQL-sandbox connection.
    if Application.get_env(:message_service, :status_sweep_async, true) do
      Task.start(fn -> run_sweep() end)
    end

    :ok
  end

  @doc false
  def run_sweep do
    %{rows: rows} =
      Repo.query!(
        "UPDATE status_posts SET media_purged_at = now() WHERE id IN (" <>
          "SELECT id FROM status_posts WHERE media_purged_at IS NULL AND deleted_at IS NULL " <>
          "AND expires_at < now() - make_interval(secs => $1) LIMIT $2) " <>
          "RETURNING id::text, media_id::text, app_id::text",
        [@sweep_grace_seconds, @sweep_batch]
      )

    Enum.each(rows, fn [status_id, media_id, app_id] ->
      purge_media(status_id, media_id, app_id)
    end)

    # Tombstones + views past the retention window die for real (CASCADE takes the views).
    Repo.query!(
      "DELETE FROM status_posts WHERE expires_at < now() - make_interval(days => $1)",
      [@purge_rows_after_days]
    )

    :ok
  rescue
    error ->
      Logger.warning("status sweep failed: #{inspect(error)}")
      :ok
  end

  defp purge_media(_status_id, nil, _app_id), do: :ok

  defp purge_media(status_id, media_id, app_id) do
    case SharedInfra.MediaClient.purge_asset(%{"media_id" => media_id, "app_id" => app_id}) do
      {:ok, _} -> :ok
      other -> Logger.warning("status media purge failed status=#{status_id} media=#{media_id}: #{inspect(other)}")
    end
  rescue
    error -> Logger.warning("status media purge raised status=#{status_id}: #{inspect(error)}")
  end

  # --- validation --------------------------------------------------------------------------------

  defp valid_kind(attrs) do
    case get_attr(attrs, "kind") do
      kind when kind in @kinds -> {:ok, kind}
      _ -> {:error, :status_invalid_kind}
    end
  end

  defp valid_content("text", attrs) do
    body = get_attr(attrs, "body")

    if is_binary(body) and String.trim(body) != "" and String.length(body) <= @max_body do
      :ok
    else
      {:error, :status_invalid_body}
    end
  end

  # image/video: media required; caption (body) optional but capped when present.
  defp valid_content(_kind, attrs) do
    media_id = get_attr(attrs, "media_id")
    body = get_attr(attrs, "body")

    cond do
      not (is_binary(media_id) and media_id != "") -> {:error, :status_media_required}
      is_binary(body) and String.length(body) > @max_body -> {:error, :status_invalid_body}
      true -> :ok
    end
  end

  # Client style hints (text background/font) ride metadata, size-capped, stringified.
  defp normalize_metadata(metadata) when is_map(metadata) do
    if map_size(metadata) <= 16, do: metadata, else: %{}
  end

  defp normalize_metadata(_metadata), do: %{}

  defp ensure_persistence do
    if Application.get_env(:message_service, :message_persistence, false) ||
         System.get_env("MESSAGE_DB_BACKED") == "true" do
      :ok
    else
      {:error, :message_unavailable}
    end
  end

  defp required(attrs, key) do
    case get_attr(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :status_invalid}
    end
  end

  defp get_attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))
end
