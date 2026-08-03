defmodule ConversationService.Conversations do
  require Logger

  @moduledoc """
  Conversation metadata boundary.
  """

  alias ConversationService.ConversationSettingsStore
  alias ConversationService.ConversationStore
  alias ConversationService.GroupProfileStore
  alias ConversationService.ParticipantEvents
  alias ConversationService.ParticipantStore
  alias ConversationService.Repo

  @type conversation_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback create_conversation(conversation_attrs()) :: result()
  @callback list_conversations(conversation_attrs()) :: result()
  @callback get_conversation(conversation_attrs()) :: result()

  def create_conversation(attrs) do
    if conversation_persistence_enabled?() do
      create_conversation_in_db(attrs)
    else
      placeholder_create_conversation(attrs)
    end
  end

  def list_conversations(attrs) do
    if conversation_persistence_enabled?() do
      list_conversations_from_db(attrs)
    else
      placeholder_list_conversations()
    end
  end

  @doc """
  Admin oversight: a paginated, cross-tenant list of conversations with METADATA ONLY (id, type, title,
  app_id, status, last activity, participant + message COUNTS) — never any message content. Admin-gated
  at the gateway; deliberately not tenant-scoped (the /v1 path is). Optional `q` searches title / id.
  """
  def admin_list_conversations(attrs) do
    if conversation_persistence_enabled?() do
      page = admin_page(attrs)
      page_size = 25
      offset = (page - 1) * page_size
      {where, params} = admin_conv_filter(attrs)

      # uuid columns ::text for Jason. Counts are subqueries (metadata only — no body/content selected).
      sql =
        "SELECT c.id::text, c.type, c.title, c.app_id::text, c.status, " <>
          "to_char(c.updated_at, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS last_activity, " <>
          "(SELECT count(*) FROM conversation_participants p WHERE p.conversation_id = c.id) AS participant_count, " <>
          "(SELECT count(*) FROM messages m WHERE m.conversation_id = c.id) AS message_count " <>
          "FROM conversations c #{where} " <>
          "ORDER BY c.updated_at DESC LIMIT #{page_size} OFFSET #{offset}"

      %Postgrex.Result{rows: rows} = Repo.query!(sql, params)

      {:ok,
       %{
         page: page,
         page_size: page_size,
         conversations:
           Enum.map(rows, fn [id, type, title, app_id, status, last_activity, pcount, mcount] ->
             %{
               conversation_id: id,
               type: type,
               title: title,
               app_id: app_id,
               status: status,
               last_activity: last_activity,
               participant_count: pcount,
               message_count: mcount
             }
           end)
       }}
    else
      {:ok, %{page: 1, page_size: 25, conversations: []}}
    end
  end

  defp admin_page(attrs) do
    case Integer.parse(to_string(attrs["page"] || attrs[:page] || "1")) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  # Admin console is first-party only → ALWAYS scope to the tenant ($1); the optional search is $2.
  defp admin_conv_filter(attrs) do
    app = SharedInfra.Tenancy.app_id_or_default(get_attr(attrs, "app_id"))

    case attrs["q"] || attrs[:q] do
      q when is_binary(q) and q != "" ->
        {"WHERE c.app_id = $1 AND (c.title ILIKE $2 OR c.id::text ILIKE $2)",
         [app_uuid(app), "%#{q}%"]}

      _ ->
        {"WHERE c.app_id = $1", [app_uuid(app)]}
    end
  end

  defp app_uuid(value) do
    case Ecto.UUID.dump(value) do
      {:ok, binary} -> binary
      :error -> value
    end
  end

  @doc """
  Admin oversight: a given user's conversations (who they've chatted with), METADATA ONLY — never message
  content. Each row carries the OTHER participant's name (display_name → phone → id, for the direct-chat
  peer that isn't this user), the group title, message/participant counts, and last activity. Admin-gated
  at the gateway.
  """
  def admin_user_conversations(attrs) do
    if conversation_persistence_enabled?() do
      # uuid columns need the 16-byte binary param (Postgrex can't infer a string for `= $1`).
      case Ecto.UUID.dump(to_string(get_attr(attrs, "user_id") || "")) do
        {:ok, uuid_bin} ->
          # Admin console is first-party only → only this tenant's conversations ($2).
          app_bin = app_uuid(SharedInfra.Tenancy.app_id_or_default(get_attr(attrs, "app_id")))

          sql =
            "SELECT c.id::text, c.type, c.title, c.status, " <>
              "to_char(c.updated_at, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS last_activity, " <>
              "(SELECT count(*) FROM messages m WHERE m.conversation_id = c.id) AS message_count, " <>
              "(SELECT count(*) FROM conversation_participants p WHERE p.conversation_id = c.id) AS participant_count, " <>
              "(SELECT COALESCE(up.display_name, ua.phone_number, o.user_id::text) " <>
              "   FROM conversation_participants o " <>
              "   LEFT JOIN user_profiles up ON up.user_id = o.user_id " <>
              "   LEFT JOIN users_auth ua ON ua.id = o.user_id " <>
              "   WHERE o.conversation_id = c.id AND o.user_id <> $1 " <>
              "   ORDER BY o.joined_at LIMIT 1) AS other_name " <>
              "FROM conversations c " <>
              "JOIN conversation_participants me ON me.conversation_id = c.id AND me.user_id = $1 " <>
              "WHERE c.app_id = $2 " <>
              "ORDER BY c.updated_at DESC LIMIT 100"

          %Postgrex.Result{rows: rows} = Repo.query!(sql, [uuid_bin, app_bin])

          {:ok,
           %{
             user_id: Ecto.UUID.load!(uuid_bin),
             conversations:
               Enum.map(rows, fn [id, type, title, status, last_activity, mcount, pcount, other] ->
                 %{
                   conversation_id: id,
                   type: type,
                   title: title,
                   status: status,
                   last_activity: last_activity,
                   message_count: mcount,
                   participant_count: pcount,
                   other_name: other
                 }
               end)
           }}

        _ ->
          {:error, :invalid_request}
      end
    else
      {:ok, %{conversations: []}}
    end
  end

  def get_conversation(attrs) do
    if conversation_persistence_enabled?() do
      get_conversation_from_db(attrs)
    else
      placeholder_get_conversation(attrs)
    end
  end

  @doc """
  Lightweight tenant lookup for the public /v1 gate: the conversation's app_id + type, WITHOUT a
  membership check (a secret-key server acts for the whole app, not as a participant). The /v1 layer
  compares this app_id to the caller's app_id and 404s on mismatch (no cross-tenant existence reveal).
  """
  def get_conversation_app(attrs) do
    if conversation_persistence_enabled?() do
      with {:ok, conversation_id} <- required_attr(attrs, "conversation_id") do
        case get_attr(attrs, "app_id") do
          app_id when is_binary(app_id) and app_id != "" ->
            # Tenant-scoped path (public /v1 gate): the (app_id, id) predicate IS the isolation
            # boundary — a cross-tenant OR unknown id both return :conversation_not_found, so the
            # caller can 404 without ever confirming another tenant's conversation exists.
            case ConversationStore.get_conversation_in_app(conversation_id, app_id) do
              nil -> {:error, :conversation_not_found}
              conversation -> {:ok, conversation_summary(conversation)}
            end

          _ ->
            # Legacy lightweight path (realtime socket authz): fetch by id, the caller compares
            # the returned app_id against the socket's own app_id.
            with {:ok, conversation} <- fetch_active_conversation(conversation_id) do
              {:ok,
               %{
                 conversation_id: conversation.id,
                 app_id: conversation.app_id,
                 type: conversation.type
               }}
            end
        end
      end
    else
      {:error, :conversation_not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :conversation_invalid}
  end

  @doc """
  Resolve a call to its parent conversation for the realtime call-topic gate: a call
  (`call_sessions.id`) belongs to exactly one conversation (`call_sessions.conversation_id`). Returns
  `{:ok, %{conversation_id}}` — the realtime layer then runs the SAME conversation tenant + membership
  gate on that id, so a cross-tenant/unknown call is rejected without any call-existence reveal. Raw SQL
  (Postgrex, `::text::uuid`) because `call_sessions` has no Ecto schema (it inherits tenancy via its
  conversation — there is no reliable call-level app_id).
  """
  def get_call_conversation(attrs) do
    if conversation_persistence_enabled?() do
      with {:ok, call_id} <- required_attr(attrs, "call_id") do
        case Repo.query(
               "SELECT conversation_id::text FROM call_sessions WHERE id = $1::text::uuid",
               [call_id]
             ) do
          {:ok, %{rows: [[conversation_id]]}} -> {:ok, %{conversation_id: conversation_id}}
          _ -> {:error, :conversation_not_found}
        end
      end
    else
      {:error, :conversation_not_found}
    end
  rescue
    _ -> {:error, :conversation_invalid}
  end

  # The tenant-scoped conversation view returned to the public /v1 layer (the GET response + the
  # message-send gate). app_id is the caller's OWN tenant, so exposing it is not a cross-tenant leak.
  defp conversation_summary(conversation) do
    %{
      conversation_id: conversation.id,
      app_id: conversation.app_id,
      type: conversation.type,
      title: conversation.title,
      created_by: conversation.created_by,
      status: conversation.status,
      created_at: iso8601(conversation.created_at)
    }
  end

  defp get_conversation_from_db(attrs) do
    with {:ok, conversation_id} <- required_attr(attrs, "conversation_id"),
         {:ok, user_id} <- required_attr(attrs, "user_id"),
         {:ok, conversation} <- fetch_active_conversation(conversation_id),
         {:ok, _participant} <- fetch_active_participant(conversation_id, user_id) do
      participants =
        conversation_id
        |> ParticipantStore.list_active_participants()
        |> Enum.map(&participant_response/1)

      {:ok,
       conversation_detail_response(
         conversation,
         participants,
         group_avatar(conversation),
         only_admins_can_send(conversation),
         call_start_permission(conversation)
       )}
    end
  rescue
    Ecto.Query.CastError -> {:error, :conversation_invalid}
  end

  # Group avatar id/key for the detail payload (the gateway presigns → group_avatar_url). nil for DMs.
  defp group_avatar(%{type: "group", id: id}) do
    case GroupProfileStore.get_group_profile(id) do
      %{avatar_media_id: media_id, avatar_object_key: key} when is_binary(media_id) ->
        %{avatar_media_id: media_id, avatar_object_key: key}

      _ ->
        nil
    end
  end

  defp group_avatar(_), do: nil

  # The ONE place a conversation's display name is resolved (the Elixir twin of the inbox SQL's
  # COALESCE(gp.name, c.title)): `group_profiles.name` is the source of truth for a group — it is what
  # `set_group_profile` writes — and `conversations.title` is the fallback. A DIRECT chat has no
  # group_profiles row at all (see maybe_create_group_profile/1), so it always resolves to c.title.
  #
  # Resolving on READ rather than writing the name to two columns is deliberate: two writable copies of a
  # name is a drift source, and every group renamed BEFORE this change already has the right value in
  # gp.name — reading it fixes them all with no backfill.
  defp resolved_title(%{type: "group", id: id, title: title}) do
    case GroupProfileStore.get_group_profile(id) do
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> title
    end
  end

  defp resolved_title(%{title: title}), do: title

  defp fetch_active_conversation(conversation_id) do
    case ConversationStore.get_conversation(conversation_id) do
      nil -> {:error, :conversation_not_found}
      %{status: "active"} = conversation -> {:ok, conversation}
      _conversation -> {:error, :conversation_not_found}
    end
  end

  defp fetch_active_participant(conversation_id, user_id) do
    case ParticipantStore.get_participant(conversation_id, user_id) do
      nil -> {:error, :conversation_forbidden}
      %{left_at: nil} = participant -> {:ok, participant}
      _participant -> {:error, :conversation_forbidden}
    end
  end

  defp only_admins_can_send(%{type: "group", id: id}) do
    case ConversationSettingsStore.get_settings(id) do
      %{only_admins_can_send: true} -> true
      _ -> false
    end
  end

  defp only_admins_can_send(_), do: false

  # Who may start a group call — "everyone" (default) or "admins_only" (Phase-3). Non-groups / no settings
  # row → "everyone".
  defp call_start_permission(%{type: "group", id: id}) do
    case ConversationSettingsStore.get_settings(id) do
      %{call_start_permission: perm} when is_binary(perm) -> perm
      _ -> "everyone"
    end
  end

  defp call_start_permission(_), do: "everyone"

  defp conversation_detail_response(
         conversation,
         participants,
         group_avatar,
         only_admins_can_send,
         call_start_permission
       ) do
    %{
      conversation_id: conversation.id,
      tenant_id: conversation.tenant_id,
      # The app (tenant) that owns this conversation — lets the /v1 layer reject cross-tenant access
      # (a conversation not in the caller's app_id → 404).
      app_id: conversation.app_id,
      type: conversation.type,
      # SAME resolution as the inbox SQL's COALESCE(gp.name, c.title) — detail and inbox must never disagree
      # about a group's name (see resolved_title/1).
      title: resolved_title(conversation),
      created_by: conversation.created_by,
      participants: participants,
      # Group photo id (nil for DMs / no photo) — the gateway presigns into group_avatar_url FROM THIS media_id
      # (with_group_avatar_url/2). The raw object_key is NOT emitted: no consumer reads it (the gateway presigns
      # from the media_id, the web reads the presigned url), and clients must never see a raw storage key
      # (Android contract §8.6).
      group_avatar_media_id: group_avatar && group_avatar.avatar_media_id,
      # Group admin setting — the client locks the composer for non-admins when true.
      only_admins_can_send: only_admins_can_send,
      # Group-call permission — the client gates the "start call" button (Phase-3).
      call_start_permission: call_start_permission
    }
  end

  defp participant_response(participant) do
    %{
      user_id: participant.user_id,
      role: participant.role,
      joined_at: iso8601(participant.joined_at),
      left_at: iso8601(participant.left_at)
    }
  end

  defp placeholder_get_conversation(attrs) do
    {:ok,
     %{
       conversation_id: Map.get(attrs, "conversation_id", "conv_placeholder"),
       tenant_id: nil,
       type: "group",
       title: "Launch Team",
       participants: ConversationService.Participants.placeholder_participants()
     }}
  end

  defp list_conversations_from_db(attrs) do
    with {:ok, user_id} <- required_attr(attrs, "user_id") do
      # ?archived=true → the archived list; otherwise the default list EXCLUDES archived chats entirely.
      scope = if archived_filter?(attrs), do: "archived", else: "active"
      {:ok, %{conversations: list_rows_with_activity(user_id, scope)}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :conversation_invalid}
  end

  defp archived_filter?(attrs) do
    get_attr(attrs, "archived") in [true, "true", "1", "yes"]
  end

  @doc """
  The inbox rows for ONE conversation as seen by EACH of `user_ids` — what the gateway broadcasts as
  `conversation_updated` (one frame per participant, each carrying THAT user's own view).

  Not a counts-only endpoint, because an inbox row is per-user in more than just its unread count: the
  preview and the activity timestamp are filtered by the SAME per-participant `cleared_before` /
  `auto_delete_seconds` window (see `@inbox_sql`). A user who cleared their history must not be shown a
  preview of a message they can no longer see, so the broadcaster cannot build one shared row + per-user
  counts. It gets a whole row per user, from the SAME SQL the inbox list runs.

  Returns `%{rows: [row_with_user_id]}` — a LIST, not a `%{user_id => …}` map: the internal-API envelope
  re-atomizes map keys (`String.to_existing_atom`), and user-id keys are UUIDs, not atoms.

  Users who are no longer active participants (`left_at` set) simply have no row — a removed member is
  absent from the result rather than being reported with a zero count.
  """

  def inbox_rows(attrs) do
    with {:ok, conversation_id} <- required_attr(attrs, "conversation_id"),
         {:ok, user_ids} <- required_user_ids(attrs) do
      if conversation_persistence_enabled?() do
        with {:ok, conversation_uuid} <- dump_uuid(conversation_id),
             {:ok, user_uuids} <- dump_uuids(user_ids) do
          # 'any': the broadcast frame must carry a conversation's row even when it's ARCHIVED, so the client
          # updates its archived/pinned flags live (the list-vs-archived split is a read-time concern).
          {:ok, %{rows: query_inbox_rows(user_uuids, conversation_uuid, "any")}}
        end
      else
        {:ok, %{rows: []}}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :conversation_invalid}
  end

  @doc """
  Do two users SHARE any active conversation? — the "contacts" relation for presence (WhatsApp semantics: you
  can see the presence of people you're in a conversation with). Both must be ACTIVE participants (left_at
  NULL) of the SAME conversation. Read-only self-join; returns `%{shares: boolean}`.
  """
  def shares_conversation?(attrs) do
    with {:ok, user_a} <- required_attr(attrs, "user_a"),
         {:ok, user_b} <- required_attr(attrs, "user_b") do
      cond do
        not conversation_persistence_enabled?() ->
          {:ok, %{shares: false}}

        user_a == user_b ->
          # A user always "shares" with themselves — but presence-of-self is never gated, so this is moot;
          # return false so the caller never treats self as a contact edge.
          {:ok, %{shares: false}}

        true ->
          with {:ok, a} <- dump_uuid(user_a), {:ok, b} <- dump_uuid(user_b) do
            %Postgrex.Result{rows: [[shares]]} =
              ConversationService.Repo.query!(
                """
                SELECT EXISTS (
                  SELECT 1
                  FROM conversation_participants pa
                  JOIN conversation_participants pb ON pb.conversation_id = pa.conversation_id
                  WHERE pa.user_id = $1 AND pa.left_at IS NULL
                    AND pb.user_id = $2 AND pb.left_at IS NULL
                )
                """,
                [a, b]
              )

            {:ok, %{shares: shares}}
          end
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :conversation_invalid}
  end

  # THE ONE inbox-row query. Both the inbox list (one user, every conversation) and the per-user broadcast
  # rows (one conversation, many users) run THIS text. A second copy of the unread/preview rules would drift,
  # and a drifted unread count is a wrong badge on every client — so the two callers differ ONLY in the two
  # bind params:
  #
  #   $1 = user_ids   (uuid[])         — one user for the list, every participant for a broadcast
  #   $2 = conversation_id (uuid|NULL) — NULL for the list ("every conversation I'm in"), one id to broadcast
  #
  # Everything is keyed on the JOINED `cp` row (not on `$1`), which is what lets one text serve both: the
  # unread count excludes YOUR OWN messages (`m.sender_user_id <> cp.user_id` — so a sender's own unread never
  # increases when they send) and the ones you have READ, and both the preview and the unread window honour
  # YOUR clear-chat (`cleared_before`) and YOUR disappearing-message setting (`auto_delete_seconds`).
  #
  # TITLE resolves as COALESCE(gp.name, c.title): `group_profiles.name` is the source of truth for a group's
  # name (it is what `set_group_profile` writes), and `conversations.title` is the fallback — and the only
  # value a DIRECT chat has, since no group_profiles row is ever created for one. This COALESCE is why a
  # renamed group now shows its new name in the inbox: previously the list read `c.title`, which the rename
  # path never touched.
  @inbox_sql """
  SELECT cp.user_id::text, c.id::text, c.type, COALESCE(gp.name, c.title),
         CASE WHEN vis.ok THEN c.last_message_body END,
         CASE WHEN vis.ok THEN c.last_message_type END,
         CASE WHEN vis.ok THEN c.last_message_content_type END,
         to_char((CASE WHEN vis.ok THEN c.last_message_at ELSE c.updated_at END) AT TIME ZONE 'UTC',
                 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
         COALESCE(rc.recount, cp.unread_count)::int,
         gp.avatar_media_id::text,
         (cp.pinned_at IS NOT NULL),
         (cp.archived_at IS NOT NULL),
         COALESCE(tg.tag_ids, ARRAY[]::text[]),
         cp.unread_count::int,
         rc.recount::int
  FROM conversations c
  JOIN conversation_participants cp
    ON cp.conversation_id = c.id AND cp.user_id = ANY($1::uuid[]) AND cp.left_at IS NULL
  LEFT JOIN group_profiles gp ON gp.conversation_id = c.id
  -- DENORMALISED (086): preview + unread come from MAINTAINED columns; this query no longer reads
  -- `messages` on any happy path. The preview is conversation-GLOBAL and per-user variation is this
  -- MASK: the newest message is always the LAST to leave any window, so "is the newest visible to
  -- THIS user" is one boolean over the participant's own prefs — no fallback to an older message is
  -- ever needed (if the newest is outside the window, everything older is too).
  LEFT JOIN LATERAL (
    SELECT (c.last_message_at IS NOT NULL
            AND (cp.cleared_before IS NULL OR c.last_message_at > cp.cleared_before)
            AND (cp.auto_delete_seconds IS NULL
                 OR c.last_message_at > now() - make_interval(secs => cp.auto_delete_seconds))) AS ok
  ) vis ON true
  -- THE FRESHNESS EXCEPTION: a maintained counter cannot decay as a rolling auto-delete window moves
  -- (messages age out with no write anywhere). `oldest_unread_at` is the trustworthiness watermark:
  -- when it has (or may have) aged out, recount inline — the CASE short-circuits, so the messages
  -- scan runs ONLY for rows that fail the test (auto-delete on, unread > 0, watermark stale). The
  -- app-side mapper write-repairs any row where this fired (InboxCounters.repair/3).
  LEFT JOIN LATERAL (
    SELECT CASE
             WHEN cp.auto_delete_seconds IS NOT NULL AND cp.unread_count > 0
                  AND (cp.oldest_unread_at IS NULL
                       OR cp.oldest_unread_at <= now() - make_interval(secs => cp.auto_delete_seconds))
               THEN (SELECT count(*)::int FROM messages m
                     WHERE m.conversation_id = c.id AND m.deleted_at IS NULL
                       AND m.sender_user_id <> cp.user_id
                       AND (cp.cleared_before IS NULL OR m.created_at > cp.cleared_before)
                       AND m.created_at > now() - make_interval(secs => cp.auto_delete_seconds)
                       AND NOT EXISTS (
                         SELECT 1 FROM message_receipts r
                         WHERE r.conversation_id = c.id AND r.message_id = m.message_id
                           AND r.user_id = cp.user_id AND (r.status = 'read' OR r.read_at IS NOT NULL)))
           END AS recount
  ) rc ON true
  -- THE CALLER'S OWN tags on this conversation. Anchored on cp.user_id, so a row can only ever carry
  -- the tags of the user the row is for — another participant's tags are unreachable from here, not
  -- merely filtered out. Rides conversation_tag_assignments(conversation_id) from migration 085.
  LEFT JOIN LATERAL (
    SELECT array_agg(t.id::text ORDER BY t.position, t.created_at) AS tag_ids
    FROM conversation_tag_assignments a
    JOIN conversation_tags t ON t.id = a.tag_id AND t.owner_user_id = cp.user_id
    WHERE a.conversation_id = c.id
  ) tg ON true
  WHERE c.status = 'active'
    AND ($2::uuid IS NULL OR c.id = $2::uuid)
    -- ARCHIVE SCOPE ($3): 'active' hides archived (the default list), 'archived' shows only archived (the
    -- ?archived=true list), 'any' ignores it (the single-conversation broadcast / unread_before, so an
    -- archived row still flows to update the client's flags). ARCHIVED rows are EXCLUDED, not sorted last.
    AND ($3 = 'any'
         OR ($3 = 'active' AND cp.archived_at IS NULL)
         OR ($3 = 'archived' AND cp.archived_at IS NOT NULL))
  -- PINNED first (newest-activity within each group), then everyone else by activity — the MASKED
  -- activity time, matching what the row displays. One ORDER BY for both the list and the
  -- conversation_updated frame, so pin order can never drift between them.
  ORDER BY (cp.pinned_at IS NOT NULL) DESC,
           (CASE WHEN vis.ok THEN c.last_message_at ELSE c.updated_at END) DESC
  """

  # WhatsApp-style list rows straight from the shared store (one query, lateral joins):
  #   * last VISIBLE message (body/type/content-type) — the caller's clear-chat / auto-delete window
  #     applies, so previews agree with their timeline;
  #   * unread = others' visible messages without the caller's read receipt;
  #   * ordered by last activity (last message, else conversation update) DESC.
  # The messages/receipts tables live in the same Postgres (same precedent as the message service
  # reading conversation_participants). READ-only.
  defp list_rows_with_activity(user_id, scope) do
    {:ok, user_uuid} = Ecto.UUID.dump(user_id)

    # One user, every conversation → the conversation filter ($2) is NULL; scope ($3) is 'active'|'archived'.
    user_uuid
    |> List.wrap()
    |> query_inbox_rows(nil, scope)
    |> Enum.map(&Map.delete(&1, :user_id))
  end

  defp query_inbox_rows(user_uuids, conversation_uuid, scope) do
    %Postgrex.Result{rows: rows} =
      ConversationService.Repo.query!(@inbox_sql, [user_uuids, conversation_uuid, scope])

    Enum.map(rows, fn [
                        user_id,
                        id,
                        type,
                        title,
                        body,
                        message_type,
                        content_type,
                        activity_at,
                        unread,
                        avatar_media_id,
                        pinned,
                        archived,
                        tag_ids,
                        raw_unread,
                        recount
                      ] ->
      # READ-REPAIR (086): `recount` is non-nil only when the freshness exception fired (auto-delete
      # window moved past the watermark). Persist the correction so the exception stops firing for
      # this row — rare by construction, bounded to one recount write per stale row per read.
      if is_integer(recount) and recount != raw_unread do
        ConversationService.InboxCounters.repair(id, user_id, recount)
      end

      %{
        user_id: user_id,
        conversation_id: id,
        type: type,
        title: title,
        last_message_preview: preview_text(body, message_type),
        last_message_kind: message_kind(message_type, content_type),
        unread_count: unread,
        updated_at: activity_at,
        # Group photo id (nil for DMs / no photo) — the gateway presigns into group_avatar_url FROM THIS
        # media_id. The raw object_key is NOT emitted: it has no consumer and must never reach a client
        # (Android §8.6). This row also feeds the conversation_updated broadcast frame, which had been leaking
        # the key on the wire (see SharedInfra.ConversationBroadcast.updated_row/1's guard).
        group_avatar_media_id: avatar_media_id,
        # Per-user inbox prefs — DERIVED booleans, not the raw timestamps (the client sorts by the server's
        # ORDER BY and renders the pin/archive state from these; it never needs the times).
        pinned: pinned,
        archived: archived,
        # The caller's OWN tag ids (never names/colours — those come from list_tags/1, at most 20 rows
        # that change rarely). Carrying the ids here is what lets a tag change reach the user's other
        # devices through the EXISTING :pref broadcast: pref_mutation recomputes this row, so the frame
        # already carries the new state and no new event or refetch is needed. Filtering is CLIENT-side.
        tag_ids: tag_ids
      }
    end)
  end

  defp required_user_ids(attrs) do
    case get_attr(attrs, "user_ids") do
      ids when is_list(ids) and ids != [] ->
        case Enum.filter(ids, &(is_binary(&1) and &1 != "")) do
          [] -> {:error, :conversation_invalid}
          valid -> {:ok, Enum.uniq(valid)}
        end

      _ ->
        {:error, :conversation_invalid}
    end
  end

  defp dump_uuid(id) do
    case Ecto.UUID.dump(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :conversation_invalid}
    end
  end

  defp dump_uuids(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case Ecto.UUID.dump(id) do
        {:ok, uuid} -> {:cont, {:ok, [uuid | acc]}}
        :error -> {:halt, {:error, :conversation_invalid}}
      end
    end)
  end

  # The row subtitle text: a text message's body; nil for media (the client renders a kind label). A
  # "call" (missed-call) message carries a short human body ("Missed voice call") — surface it verbatim so
  # the list preview matches the in-thread entry (client has no separate call-kind label).
  defp preview_text(body, "text") when is_binary(body) and body != "", do: body
  defp preview_text(body, nil) when is_binary(body) and body != "", do: body
  defp preview_text(body, "call") when is_binary(body) and body != "", do: body
  defp preview_text(_body, _type), do: nil

  defp message_kind(nil, _content_type), do: nil
  defp message_kind("text", _content_type), do: "text"

  defp message_kind("media", content_type) do
    ct = to_string(content_type)

    cond do
      String.starts_with?(ct, "image/") -> "image"
      String.starts_with?(ct, "video/") -> "video"
      String.starts_with?(ct, "audio/") -> "audio"
      true -> "file"
    end
  end

  defp message_kind(other, _content_type), do: other

  defp placeholder_list_conversations do
    {:ok,
     %{
       conversations: [
         %{
           conversation_id: "conv_placeholder",
           type: "group",
           title: "Launch Team",
           last_message_preview: nil,
           unread_count: 0,
           updated_at: "2026-06-17T10:00:00Z"
         }
       ]
     }}
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp create_conversation_in_db(attrs) do
    with {:ok, type} <- required_attr(attrs, "type"),
         {:ok, created_by} <- required_attr(attrs, "created_by"),
         {:ok, participant_user_ids} <- required_participant_user_ids(attrs) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      conversation_id = get_attr(attrs, "conversation_id") || Ecto.UUID.generate()

      participant_user_ids =
        participant_user_ids
        |> Enum.concat([created_by])
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      # The app (tenant) this conversation belongs to. The existing single-tenant gateway passes none →
      # tenant zero. Set explicitly so direct dedup keys + the (app_id, direct_key) unique index scope
      # per-app (and future per-app callers just pass their app_id).
      app_id = SharedInfra.Tenancy.app_id_or_default(get_attr(attrs, "app_id"))

      base_attrs = %{
        "id" => conversation_id,
        "tenant_id" => get_attr(attrs, "tenant_id"),
        "app_id" => app_id,
        "type" => type,
        "title" => get_attr(attrs, "title"),
        "avatar_media_id" => get_attr(attrs, "avatar_media_id"),
        "created_by" => created_by,
        "status" => "active",
        "created_at" => now,
        "updated_at" => now
      }

      # A 1:1 direct chat (exactly two distinct participants) is idempotent per user-pair WITHIN the app:
      # return the existing thread for the pair if there is one, else create it. Everything else inserts.
      result =
        if type == "direct" and length(participant_user_ids) == 2 do
          find_or_create_direct(app_id, base_attrs, created_by, participant_user_ids, now)
        else
          insert_conversation(base_attrs, created_by, participant_user_ids, now)
        end

      case result do
        {:ok, response, :created} ->
          # Emit one participant_added per initial participant ONLY for a newly created conversation
          # (fire-and-forget; never affects the result). Returning an existing thread stays silent.
          ParticipantEvents.publish_initial_participants(
            response.conversation_id,
            response.created_by,
            response.participant_user_ids
          )

          # Surface whether this was a genuine INSERT vs. a returned-existing direct, so the gateway can
          # broadcast conversation_created ONLY on a real insert (never on an idempotent direct return).
          # `created` MUST live here as a MAP FIELD (not in conversation_response/2 — that builder is SHARED
          # by both the :created and :existing paths, so it can't set it) and NOT as a 3rd tuple element (a
          # tuple element can't cross the ConversationClientHttp boundary; a map field does — see the
          # round-trip test). This is the value ApiGatewayWeb.ConversationBroadcast gates the broadcast on.
          {:ok, Map.put(response, :created, true)}

        {:ok, response, :existing} ->
          {:ok, Map.put(response, :created, false)}

        {:error, _reason} ->
          {:error, :conversation_invalid}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :conversation_invalid}
  end

  # Normal (non-deduped) create: conversation + initial participants in one transaction.
  defp insert_conversation(base_attrs, created_by, participant_user_ids, now) do
    Repo.transaction(fn ->
      with {:ok, conversation} <- ConversationStore.create_conversation(base_attrs),
           :ok <-
             add_initial_participants(conversation.id, created_by, participant_user_ids, now),
           :ok <- maybe_create_group_profile(conversation) do
        # TRANSACTIONAL OUTBOX: emit conversation.created in the SAME transaction (same Repo) as the
        # conversation + participant inserts, scoped to the conversation's app_id. Atomic with the write.
        emit_conversation_created(conversation, participant_user_ids)

        conversation_response(conversation, participant_user_ids)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, response} -> {:ok, response, :created}
      {:error, reason} -> {:error, reason}
    end
  end

  # Groups get a group_profiles row on creation (name = title) so the name/photo can be edited later.
  # Direct chats have no group profile. Best-effort inside the txn: a failure rolls the create back.
  defp maybe_create_group_profile(%{type: "group"} = conversation) do
    case GroupProfileStore.create_group_profile(%{
           "conversation_id" => conversation.id,
           "name" => conversation.title || "Group"
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_create_group_profile(_conversation), do: :ok

  @doc """
  OWNER-gated group name/photo update. The caller must be an active OWNER (or admin) of the group.
  Empty-string avatar fields = REMOVE the photo (→ nil, mirroring the user-avatar clear); nil =
  unchanged. Lazy-creates the group_profiles row for groups that predate it.
  """
  def set_group_profile(attrs) do
    with {:ok, conversation_id} <- required_attr(attrs, "conversation_id"),
         {:ok, user_id} <- required_attr(attrs, "actor_user_id") do
      if conversation_persistence_enabled?() do
        set_group_profile_in_db(conversation_id, user_id, attrs)
      else
        {:ok, %{conversation_id: conversation_id, updated: true}}
      end
    end
  end

  defp set_group_profile_in_db(conversation_id, user_id, attrs) do
    with {:ok, conversation} <- fetch_active_conversation(conversation_id),
         :ok <- ensure_group(conversation),
         {:ok, participant} <- fetch_active_participant(conversation_id, user_id),
         :ok <- ensure_owner_or_admin(participant),
         changes when changes != %{} <- group_profile_changes(attrs),
         {:ok, profile} <- upsert_group_profile(conversation, changes) do
      {:ok,
       %{
         conversation_id: conversation_id,
         name: profile.name,
         avatar_media_id: profile.avatar_media_id,
         avatar_object_key: profile.avatar_object_key
       }}
    else
      %{} -> {:error, :conversation_invalid}
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.Query.CastError -> {:error, :conversation_invalid}
  end

  defp ensure_group(%{type: "group"}), do: :ok
  defp ensure_group(_), do: {:error, :conversation_invalid}

  # RENAMED from `ensure_owner`, which asserted the opposite of what it does: it accepts ADMINS too.
  # Someone mirroring "the ensure_owner rule" by name would have got the wrong tier — the same shape of
  # mistake as reusing a trigger by name without reading its scope. The genuinely owner-only gate is
  # `Participants.require_owner/2` (used by add_participant); this is the owner+admin tier, matching
  # `Participants.require_owner_or_admin/2`.
  defp ensure_owner_or_admin(%{role: role}) when role in ["owner", "admin"], do: :ok
  defp ensure_owner_or_admin(_), do: {:error, :conversation_forbidden}

  # Whitelist name/avatar changes. "" on an avatar field → nil (clear); nil → omitted (unchanged).
  defp group_profile_changes(attrs) do
    [
      {"name", "name"},
      {"avatar_media_id", "avatar_media_id"},
      {"avatar_object_key", "avatar_object_key"}
    ]
    |> Enum.reduce(%{}, fn {src, dest}, acc ->
      case Map.get(attrs, src) do
        nil -> acc
        "" when dest in ["avatar_media_id", "avatar_object_key"] -> Map.put(acc, dest, nil)
        "" -> acc
        value -> Map.put(acc, dest, value)
      end
    end)
  end

  defp upsert_group_profile(conversation, changes) do
    case GroupProfileStore.get_group_profile(conversation.id) do
      nil ->
        GroupProfileStore.create_group_profile(
          Map.merge(
            %{"conversation_id" => conversation.id, "name" => conversation.title || "Group"},
            changes
          )
        )

      profile ->
        GroupProfileStore.update_group_profile(profile, changes)
    end
  end

  # Webhooks speak the integrator's EXTERNAL ids (see message_store's emit for the full rationale). All
  # participants + the creator resolve in ONE batch query under the conversation's app_id. The drop rule:
  #   * creator unresolvable → the WHOLE event is dropped (created_by is attribution; an unattributable
  #     event must never emit with an internal or blank id — the call webhooks' rule);
  #   * a PARTICIPANT unresolvable → that participant is OMITTED but the event still emits (participants
  #     are an enumeration, not attribution — a stale or first-party member shouldn't suppress the event).
  defp emit_conversation_created(conversation, participant_user_ids) do
    externals =
      external_ids_for(
        conversation.app_id,
        Enum.uniq([conversation.created_by | participant_user_ids])
      )

    case Map.fetch(externals, conversation.created_by) do
      {:ok, creator_external_id} ->
        SharedInfra.WebhookOutbox.emit(Repo, conversation.app_id, "conversation.created", %{
          "conversation_id" => conversation.id,
          "type" => conversation.type,
          "title" => conversation.title,
          "created_by_external_id" => creator_external_id,
          "participant_external_ids" =>
            participant_user_ids |> Enum.map(&Map.get(externals, &1)) |> Enum.reject(&is_nil/1)
        })

      :error ->
        Logger.warning(
          "conversation.created webhook dropped: creator #{conversation.created_by} has no external_id in app #{conversation.app_id}"
        )

        :ok
    end
  end

  # internal user_id → external_id for a batch of users, ONE query, scoped to the app (the same direct
  # users_auth read the call webhooks use — same Postgres, cross-service read precedent). Users without an
  # external_id (first-party phone/email users) are simply absent from the result map.
  defp external_ids_for(app_id, user_ids) do
    with {:ok, app_bin} <- Ecto.UUID.dump(app_id),
         {:ok, id_bins} <- dump_uuids(user_ids) do
      %Postgrex.Result{rows: rows} =
        Repo.query!(
          "SELECT id::text, external_id FROM users_auth " <>
            "WHERE app_id = $1 AND id = ANY($2) AND external_id IS NOT NULL",
          [app_bin, id_bins]
        )

      Map.new(rows, fn [id, external_id] -> {id, external_id} end)
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  # Idempotent direct create. Compute the canonical pair key, return the existing thread if present,
  # else insert it (with the key). On the unique-violation RACE (two simultaneous "Message" clicks),
  # the partial unique index rejects the loser → re-fetch by key and return the winner's thread, so
  # two rows are never created.
  defp find_or_create_direct(app_id, base_attrs, created_by, participant_user_ids, now) do
    direct_key = participant_user_ids |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(":")

    case ConversationStore.get_by_direct_key(app_id, direct_key) do
      nil ->
        base_attrs
        |> Map.put("direct_key", direct_key)
        |> insert_conversation(created_by, participant_user_ids, now)
        |> case do
          {:ok, response, :created} ->
            {:ok, response, :created}

          {:error, %Ecto.Changeset{errors: errors}} ->
            if Keyword.has_key?(errors, :direct_key) do
              refetch_direct(app_id, direct_key, participant_user_ids)
            else
              {:error, :conversation_invalid}
            end

          {:error, reason} ->
            {:error, reason}
        end

      existing ->
        {:ok, conversation_response(existing, participant_user_ids), :existing}
    end
  end

  defp refetch_direct(app_id, direct_key, participant_user_ids) do
    case ConversationStore.get_by_direct_key(app_id, direct_key) do
      nil -> {:error, :conversation_invalid}
      existing -> {:ok, conversation_response(existing, participant_user_ids), :existing}
    end
  end

  defp add_initial_participants(conversation_id, created_by, participant_user_ids, now) do
    participant_user_ids
    |> Enum.reduce_while(:ok, fn user_id, :ok ->
      role =
        if user_id == created_by do
          "owner"
        else
          "member"
        end

      case ParticipantStore.add_participant(%{
             "conversation_id" => conversation_id,
             "user_id" => user_id,
             "role" => role,
             "joined_at" => now
           }) do
        {:ok, _participant} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp conversation_response(conversation, participant_user_ids) do
    %{
      conversation_id: conversation.id,
      tenant_id: conversation.tenant_id,
      type: conversation.type,
      title: conversation.title,
      created_by: conversation.created_by,
      participant_user_ids: participant_user_ids,
      created_at: DateTime.to_iso8601(conversation.created_at)
    }
  end

  defp placeholder_create_conversation(attrs) do
    {:ok,
     %{
       conversation_id: "conv_placeholder",
       tenant_id: Map.get(attrs, "tenant_id"),
       type: Map.get(attrs, "type", "group"),
       title: Map.get(attrs, "title", "Launch Team"),
       created_by: "user_placeholder",
       participant_user_ids: Map.get(attrs, "participant_user_ids", []),
       created_at: "2026-06-17T10:00:00Z"
     }}
  end

  defp required_participant_user_ids(attrs) do
    case get_attr(attrs, "participant_user_ids") do
      user_ids when is_list(user_ids) and user_ids != [] -> {:ok, user_ids}
      _ -> {:error, :conversation_invalid}
    end
  end

  defp required_attr(attrs, key) do
    case get_attr(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :conversation_invalid}
    end
  end

  defp get_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))
  end

  defp conversation_persistence_enabled? do
    Application.get_env(:conversation_service, :conversation_persistence, false) ||
      System.get_env("CONVERSATION_DB_BACKED") in ["true", "1", "yes"]
  end
end
