defmodule ConversationService.CallStore do
  @moduledoc """
  Data-access boundary for the `calls` table (Phase-1 LiveKit calling). Owns the call lifecycle:
  create (ringing) → answer / decline / miss / end, plus point lookup + per-user history.

  Lives in conversation_service because it already owns participant/DM relationships (the conversation a
  call belongs to). Persistence-gated (`CONVERSATION_DB_BACKED`) like the rest of this service: with the
  flag OFF (default in-memory topology / unit tests) every function returns `{:error, :call_unavailable}`
  rather than touching a DB that isn't there.

  NOT related to the legacy `call_sessions`/`call_participants` tables (010) — see 066_calls.sql.
  """

  import Ecto.Query

  alias ConversationService.ConversationSettingsStore
  alias ConversationService.ParticipantStore
  alias ConversationService.Repo
  alias ConversationService.Schemas.Call
  alias ConversationService.Schemas.CallLink
  alias ConversationService.Schemas.CallParticipant

  @doc """
  Create a ringing call. attrs: "caller_id", "callee_id", "type" ('voice'|'video'), optional
  "conversation_id". Generates the id + a unique LiveKit room_name. Returns `{:ok, call}`.
  """
  def create_call(attrs) do
    with :ok <- persistence(),
         {:ok, caller_id} <- required(attrs, "caller_id"),
         {:ok, callee_id} <- required(attrs, "callee_id"),
         {:ok, type} <- required(attrs, "type"),
         # E2EE (111): OPTIONAL. Absent → exactly the pre-E2EE call, which is how old clients keep
         # working. Present → shape-validated here and stored verbatim; never parsed.
         {:ok, e2ee_offer} <- validate_e2ee_offer(get(attrs, "e2ee_offer"), caller_id, callee_id) do
      id = Ecto.UUID.generate()

      changeset =
        Call.create_changeset(%{
          id: id,
          room_name: "call-" <> id,
          # The boundary's tenant (socket assigns / v1 credential / session). Optional: nil is stored as
          # NULL (a legacy-shaped row), NEVER defaulted — inventing a tenant here is how rows go wrong.
          app_id: get(attrs, "app_id"),
          caller_id: caller_id,
          callee_id: callee_id,
          conversation_id: get(attrs, "conversation_id"),
          type: type,
          status: "ringing",
          created_at: DateTime.utc_now(),
          e2ee_offer: e2ee_offer,
          e2ee: not is_nil(e2ee_offer)
        })

      case Repo.insert(changeset) do
        {:ok, call} -> {:ok, response(call)}
        {:error, _changeset} -> {:error, :call_invalid}
      end
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  @doc """
  Caller answered → accepted + answered_at. attrs: \"call_id\", optional \"e2ee_accepted\" (bool —
  the callee opened its sealed envelope and has frame encryption armed). Emits `call.started`.

  The flag is RELAYED, not enforced: the server records what the callee reported so the caller can
  read the agreed mode, and never decides the mode itself (E2EE_FRAME.md §calls).
  """
  def mark_answered(attrs) do
    patch = %{status: "accepted", answered_at: DateTime.utc_now()}

    # NOT via get/2: that helper is `Map.get(a) || Map.get(b)`, and a legitimate `false` is falsy —
    # it would silently read as "absent" and never be recorded. Fetch both keys explicitly.
    patch =
      case fetch_either(attrs, "e2ee_accepted") do
        {:ok, accepted} when is_boolean(accepted) -> Map.put(patch, :e2ee_accepted, accepted)
        # Absent stays ABSENT (nil), not false: a plain call negotiated nothing, and writing false
        # would claim a negotiation that never happened.
        _ -> patch
      end

    transition(attrs, patch, "call.started")
  end

  @doc "Callee rejected → declined. attrs: \"call_id\". Emits `call.declined` (an ACTIVE refusal — distinct
  from `call.missed`, which is a timeout; an integrator logs those differently)."
  def mark_declined(attrs),
    do:
      transition(
        attrs,
        %{status: "declined", ended_at: DateTime.utc_now(), e2ee_offer: nil},
        "call.declined"
      )

  @doc "Never answered (ring timeout) → missed. attrs: \"call_id\". Emits `call.missed`."
  def mark_missed(attrs),
    do:
      transition(
        attrs,
        %{status: "missed", ended_at: DateTime.utc_now(), e2ee_offer: nil},
        "call.missed"
      )

  @doc """
  Caller hung up while still ringing → cancelled (097 — previously folded into `missed`). attrs:
  \"call_id\". Still emits `call.missed` to the integrator (to the callee's side it IS an unanswered
  call; the payload's `reason` carries "cancelled" for the distinction) — no new webhook event type.
  """
  def mark_cancelled(attrs),
    do:
      transition(
        attrs,
        %{status: "cancelled", ended_at: DateTime.utc_now(), e2ee_offer: nil},
        "call.missed"
      )

  @doc "Call finished (hang up) → ended. attrs: \"call_id\". Emits `call.ended` (with duration_seconds)."
  def mark_ended(attrs),
    do:
      transition(
        attrs,
        %{status: "ended", ended_at: DateTime.utc_now(), e2ee_offer: nil},
        "call.ended"
      )

  @doc "Fetch a single call by id. attrs: \"call_id\". → {:ok, call} | {:error, :call_not_found}."
  def get_call(attrs) do
    with :ok <- persistence(),
         {:ok, call_id} <- required(attrs, "call_id") do
      case Repo.get(Call, call_id) do
        nil -> {:error, :call_not_found}
        %Call{} = call -> {:ok, response(call)}
      end
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  @doc """
  Call history for a user — every call they placed OR received, most recent first. attrs: "user_id",
  optional "limit" (default 50), optional "app_id" (the session tenant — rows must match it, with
  NULL-app legacy rows still included), optional keyset cursor "cursor_ts"/"cursor_id".
  → {:ok, %{calls: [...], next_cursor: %{ts, id} | nil}}.
  """
  def list_calls_for_user(attrs) do
    with :ok <- persistence(),
         {:ok, user_id} <- required(attrs, "user_id") do
      limit = limit(attrs)

      # 1-on-1 rows: matched by caller/callee EXACTLY as before. Group rows: added via a call_participants
      # membership subquery. distinct so a row can't repeat. Old 1-on-1 history is unchanged.
      participant_calls =
        from(p in CallParticipant, where: p.user_id == ^user_id, select: p.call_id)

      query =
        from(c in Call,
          where:
            c.caller_id == ^user_id or c.callee_id == ^user_id or
              c.id in subquery(participant_calls),
          distinct: true,
          order_by: [desc: c.created_at, desc: c.id],
          limit: ^limit
        )
        |> filter_app(get(attrs, "app_id"))
        |> after_cursor(get(attrs, "cursor_ts"), get(attrs, "cursor_id"))

      rows = Repo.all(query)
      calls = Enum.map(rows, &response/1)

      next_cursor =
        case List.last(rows) do
          %Call{} = last when length(rows) == limit ->
            %{ts: iso8601(last.created_at), id: last.id}

          _ ->
            nil
        end

      {:ok, %{calls: calls, next_cursor: next_cursor}}
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  # SESSION-TENANT gating (097). Rows stamped with a DIFFERENT app never appear; NULL rows (pre-097
  # legacy) stay visible — they are already tenant-safe because caller/callee/participant user ids are
  # app-scoped uuids, so a foreign tenant's user id can never have matched the user predicate above.
  # Hiding them would empty every user's pre-097 history — the exact symptom this slice was fixing.
  defp filter_app(query, app_id) when is_binary(app_id) and app_id != "",
    do: from(c in query, where: c.app_id == ^app_id or is_nil(c.app_id))

  defp filter_app(query, _app_id), do: query

  # Keyset page: strictly older than the (created_at, id) the previous page ended on.
  defp after_cursor(query, ts, id)
       when is_binary(ts) and ts != "" and is_binary(id) and id != "" do
    case DateTime.from_iso8601(ts) do
      {:ok, cursor_at, _offset} ->
        from(c in query,
          where: c.created_at < ^cursor_at or (c.created_at == ^cursor_at and c.id < ^id)
        )

      _ ->
        query
    end
  end

  defp after_cursor(query, _ts, _id), do: query

  # ============================================================================================
  # Phase-3 group calling. ADDITIVE — the 1-on-1 functions above are untouched. A group call is a
  # `calls` row with kind="group", caller_id=initiator, callee_id=nil, plus one `call_participants`
  # row per member (initiator joined, others invited). Signaling (A2) rides on top of these.
  # ============================================================================================

  @doc """
  Start a group call. attrs: "initiator_id", "conversation_id", "type". The initiator must be an ACTIVE
  member and (if the conversation's call_start_permission is admins_only) an owner/admin. Inserts the
  `calls` row + all participant rows in ONE transaction. Returns
  `{:ok, %{call, participants, member_ids}}` where member_ids = everyone to ring (members minus initiator).
  """
  def create_group_call(attrs) do
    with :ok <- persistence(),
         {:ok, initiator_id} <- required(attrs, "initiator_id"),
         {:ok, conversation_id} <- required(attrs, "conversation_id"),
         {:ok, type} <- required(attrs, "type"),
         members <- ParticipantStore.list_active_participants(conversation_id),
         :ok <- ensure_member(members, initiator_id),
         :ok <- ensure_can_start(conversation_id, members, initiator_id) do
      id = Ecto.UUID.generate()
      now = DateTime.utc_now()
      others = members |> Enum.map(& &1.user_id) |> Enum.reject(&(&1 == initiator_id))

      app_id = get(attrs, "app_id")

      Repo.transaction(fn ->
        call = insert_call!(id, app_id, initiator_id, conversation_id, type, now)
        insert_participant!(id, initiator_id, "joined", now, now)
        Enum.each(others, fn uid -> insert_participant!(id, uid, "invited", now, nil) end)
        call
      end)
      |> case do
        {:ok, call} ->
          {:ok, %{call: response(call), participants: list_participants(id), member_ids: others}}

        {:error, _reason} ->
          {:error, :call_invalid}
      end
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  # Ring-list ceiling for an AD-HOC call. LiveKit has no configured room cap and runs in a 256MB
  # container over one muxed UDP port, so the wire contract is the only real bound; 8 covers the
  # picker use-case and bounds the no-shared-context spam primitive to 8 rings per push. A
  # conversation-backed group call still rings its whole membership — this cap is only for the
  # primitive with no admission step.
  @adhoc_target_cap 8

  @doc """
  Start an AD-HOC group call (116): the initiator names 1..#{@adhoc_target_cap} target user ids and
  there is NO conversation — membership is only the participant rows this creates.

  attrs: "initiator_id", "user_ids" (list), "type", "app_id" (the CALLER's authenticated tenant —
  from the socket session, never the payload).

  SECURITY-FIRST, ALL-OR-NOTHING. Before any row is written (and long before any ring), every target
  must: exist AND be active AND belong to the SAME app as the caller (one batch query over
  `users_auth` — the same-Postgres cross-service read precedent, so a cross-tenant id fails the same
  membership test as a nonexistent one and is INDISTINGUISHABLE by construction), and have no block
  in EITHER direction with the caller (one batch EXISTS over `user_blocks`, the exact
  `Blocks.either_blocked?/1` semantics). Any failure refuses the WHOLE invite with the single uniform
  `{:error, :invalid_targets}` — which target, and why, is never revealed: a partial ring would be a
  block/existence oracle (send [victim, friend] and watch who appears).

  `ensure_can_start` is deliberately NOT consulted: there is no conversation to read settings from;
  the caller is the organizer and "everyone" semantics hold by construction.

  Returns `{:ok, %{call, participants, member_ids}}` — the create_group_call shape, so the signaling
  fan-out code is identical.
  """
  def create_adhoc_group_call(attrs) do
    with :ok <- persistence(),
         {:ok, initiator_id} <- required(attrs, "initiator_id"),
         {:ok, type} <- required(attrs, "type"),
         {:ok, app_id} <- required(attrs, "app_id"),
         {:ok, targets} <- normalize_adhoc_targets(get(attrs, "user_ids"), initiator_id),
         :ok <- authorize_adhoc_targets(targets, initiator_id, app_id) do
      id = Ecto.UUID.generate()
      now = DateTime.utc_now()

      Repo.transaction(fn ->
        call = insert_adhoc_call!(id, app_id, initiator_id, type, now)
        insert_participant!(id, initiator_id, "joined", now, now)
        Enum.each(targets, fn uid -> insert_participant!(id, uid, "invited", now, nil) end)
        call
      end)
      |> case do
        {:ok, call} ->
          {:ok, %{call: response(call), participants: list_participants(id), member_ids: targets}}

        {:error, _reason} ->
          {:error, :call_invalid}
      end
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  # Shape + normalisation (defense in depth — the signaling layer validates first): a list of
  # non-empty binaries, deduped, the caller silently dropped, 1..cap afterwards. A malformed LIST is
  # the caller's bug; an over-cap or empty list refuses with the same uniform code as the
  # authorization checks so the error surface stays one code wide.
  defp normalize_adhoc_targets(user_ids, initiator_id) when is_list(user_ids) do
    if Enum.all?(user_ids, &(is_binary(&1) and &1 != "")) do
      targets = user_ids |> Enum.uniq() |> Enum.reject(&(&1 == initiator_id))

      if targets != [] and length(targets) <= @adhoc_target_cap,
        do: {:ok, targets},
        else: {:error, :invalid_targets}
    else
      {:error, :invalid_targets}
    end
  end

  defp normalize_adhoc_targets(_user_ids, _initiator_id), do: {:error, :invalid_targets}

  # THE PER-TARGET GATE. Two batch queries, zero cross-service round trips, refuse-before-ring.
  defp authorize_adhoc_targets(targets, initiator_id, app_id) do
    with {:ok, target_uuids} <- dump_uuid_list(targets),
         {:ok, initiator_uuid} <- dump_uuid(initiator_id),
         {:ok, app_uuid} <- dump_uuid(app_id) do
      # (a)+(b) exists + active + SAME tenant. COUNT equality is the whole test: an id that is
      # unknown, inactive, or in another app is simply absent from the result — indistinguishable.
      %Postgrex.Result{rows: [[matched]]} =
        Repo.query!(
          "SELECT count(*)::int FROM users_auth " <>
            "WHERE id = ANY($1) AND status = 'active' AND app_id = $2",
          [target_uuids, app_uuid]
        )

      # (c) blocks, BOTH directions, any pair caller<->target — Blocks.either_blocked?/1 semantics
      # ((blocker=A AND blocked=B) OR (blocker=B AND blocked=A)) applied across the whole set at once.
      %Postgrex.Result{rows: [[blocked]]} =
        Repo.query!(
          "SELECT EXISTS (SELECT 1 FROM user_blocks " <>
            "WHERE (blocker_user_id = $2 AND blocked_user_id = ANY($1)) " <>
            "   OR (blocked_user_id = $2 AND blocker_user_id = ANY($1)))",
          [target_uuids, initiator_uuid]
        )

      if matched == length(target_uuids) and blocked == false,
        do: :ok,
        else: {:error, :invalid_targets}
    end
  end

  # A non-UUID target refuses with the SAME uniform code — shape errors must not be a different
  # oracle from authorization errors.
  defp dump_uuid_list(ids) do
    dumped = Enum.map(ids, &dump_uuid/1)

    if Enum.all?(dumped, &match?({:ok, _}, &1)),
      do: {:ok, Enum.map(dumped, fn {:ok, uuid} -> uuid end)},
      else: {:error, :invalid_targets}
  end

  defp dump_uuid(id) do
    case Ecto.UUID.dump(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_targets}
    end
  end

  # The adhoc calls row: kind "adhoc", NO conversation, NO single callee — membership is exclusively
  # the participant rows written beside it.
  defp insert_adhoc_call!(id, app_id, initiator_id, type, now) do
    %{
      id: id,
      room_name: "call-" <> id,
      app_id: app_id,
      kind: "adhoc",
      caller_id: initiator_id,
      callee_id: nil,
      conversation_id: nil,
      type: type,
      status: "ringing",
      created_at: now
    }
    |> Call.create_changeset()
    |> Repo.insert!()
  end

  @doc """
  Late-join / accept a group call. attrs: "call_id", "user_id". Validates the call is a group in
  ringing/ongoing and the user is a member; upserts their participant → joined. A `ringing` call flips to
  `ongoing`. Returns `{:ok, %{call, participant}}`.
  """
  def join_group_call(attrs) do
    with :ok <- persistence(),
         {:ok, call_id} <- required(attrs, "call_id"),
         {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, call} <- fetch_group_call(call_id),
         :ok <- ensure_joinable(call),
         # A conversationless call (adhoc, 116) has no member list to consult — the empty list makes
         # ensure_member_or_participant's participant-row arm (C2) the ENTIRE rule, which is exactly
         # the adhoc contract: only someone the create/add gate seated may join. NB the nil guard is
         # load-bearing: list_active_participants(nil) raises, and the blanket rescue would turn
         # every adhoc join into :call_invalid before the participant-row arm was ever consulted.
         members <- conversation_members(call.conversation_id),
         :ok <- ensure_member_or_participant(members, call_id, user_id) do
      now = DateTime.utc_now()
      upsert_participant_status(call_id, user_id, %{status: "joined", joined_at: now})

      call =
        if call.status == "ringing" do
          {:ok, updated} = call |> Call.status_changeset(%{status: "ongoing"}) |> Repo.update()
          updated
        else
          call
        end

      {:ok,
       %{
         call: response(call),
         participant: participant_response(get_participant_row(call_id, user_id))
       }}
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  @doc "Decline a group call for one member. attrs: \"call_id\", \"user_id\". May close the call."
  def decline_group_call(attrs) do
    with :ok <- persistence(),
         {:ok, call_id} <- required(attrs, "call_id"),
         {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, call} <- fetch_group_call(call_id) do
      upsert_participant_status(call_id, user_id, %{status: "declined"})
      call = maybe_close_call(call)

      {:ok,
       %{
         call: response(call),
         participant: participant_response(get_participant_row(call_id, user_id))
       }}
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  @doc "Leave a group call. attrs: \"call_id\", \"user_id\". Closes the call when nobody remains."
  def leave_group_call(attrs) do
    with :ok <- persistence(),
         {:ok, call_id} <- required(attrs, "call_id"),
         {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, call} <- fetch_group_or_link_call(call_id) do
      now = DateTime.utc_now()
      upsert_participant_status(call_id, user_id, %{status: "left", left_at: now})
      call = maybe_close_call(call)

      {:ok,
       %{
         call: response(call),
         participant: participant_response(get_participant_row(call_id, user_id))
       }}
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  @doc """
  Ring timeout (A2 wires the timer): flip any still-`invited` members to `missed`, then close the call if
  it can no longer continue. attrs: "call_id". Returns `{:ok, %{call, participants}}`.
  """
  def mark_group_participants_missed(attrs) do
    with :ok <- persistence(),
         {:ok, call_id} <- required(attrs, "call_id"),
         {:ok, call} <- fetch_group_call(call_id) do
      from(p in CallParticipant, where: p.call_id == ^call_id and p.status == "invited")
      |> Repo.update_all(set: [status: "missed"])

      call = maybe_close_call(call)
      {:ok, %{call: response(call), participants: list_participants(call_id)}}
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  @doc "Fetch a call + all its participant rows. attrs: \"call_id\"."
  def get_call_with_participants(attrs) do
    with :ok <- persistence(),
         {:ok, call_id} <- required(attrs, "call_id") do
      case Repo.get(Call, call_id) do
        nil -> {:error, :call_not_found}
        %Call{} = call -> {:ok, %{call: response(call), participants: list_participants(call_id)}}
      end
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  @doc """
  The current ONGOING group call for a conversation — powers the "join call" banner (Slice C1). attrs:
  "conversation_id". Returns `{:ok, %{call: call}}` when a group call is in progress, else
  `{:ok, %{call: nil}}`. NEVER errors on "none" (a missing/bad conversation is just no call).
  """
  def get_ongoing_group_call(attrs) do
    with :ok <- persistence(),
         {:ok, conversation_id} <- required(attrs, "conversation_id") do
      call =
        from(c in Call,
          where:
            c.conversation_id == ^conversation_id and c.kind == "group" and c.status == "ongoing",
          order_by: [desc: c.created_at],
          limit: 1
        )
        |> Repo.one()

      {:ok, %{call: call && response(call)}}
    end
  rescue
    _ -> {:ok, %{call: nil}}
  end

  @doc """
  Add a participant to an ONGOING/ringing group call (Phase-3 C2). attrs: "call_id", "actor_id", "user_id".
  The `actor_id` must be allowed to add — same rule as starting a call: an ACTIVE member, and (under
  `admins_only`) an owner/admin. The `user_id` being added need NOT be a conversation member (adding an
  outside person to THIS call only — they get a participant row, never a conversation membership). Idempotent:
  re-adding someone with a live invited/joined row is a no-op; a prior declined/left/missed row is re-invited.
  Returns `{:ok, %{call, added_user_id, room, type, conversation_id}}` so signaling can ring them.
  """
  def add_call_participant(attrs) do
    with :ok <- persistence(),
         {:ok, call_id} <- required(attrs, "call_id"),
         {:ok, actor_id} <- required(attrs, "actor_id"),
         {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, call} <- fetch_group_call(call_id),
         :ok <- ensure_joinable(call),
         :ok <- authorize_add(call, actor_id, user_id) do
      ensure_invited_participant(call_id, user_id)

      {:ok,
       %{
         call: response(call),
         added_user_id: user_id,
         room: call.room_name,
         type: call.type,
         conversation_id: call.conversation_id
       }}
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  @doc """
  Authorization predicate for the LiveKit token endpoint: does (call_id, user_id) have a
  `group_call_participants` row whose status is NOT `pending_approval`? Any admitted status
  (invited/joined/declined/left/missed) authorizes; a call-link joiner still waiting for the host
  (`pending_approval`, L3a) does NOT (the token 403s until the host approves → row flips to `joined`). Group
  calls are unaffected — their rows are never pending. attrs: "call_id", "user_id". Returns
  `{:ok, %{authorized: boolean}}` (never errors — a missing/bad id or DB-off is `authorized: false` = fail closed).
  """
  def call_participant?(attrs) do
    with :ok <- persistence(),
         {:ok, call_id} <- required(attrs, "call_id"),
         {:ok, user_id} <- required(attrs, "user_id") do
      {:ok, %{authorized: authorized_participant?(call_id, user_id)}}
    else
      _ -> {:ok, %{authorized: false}}
    end
  rescue
    _ -> {:ok, %{authorized: false}}
  end

  @doc """
  Promote a LIVE 1-on-1 (direct) call to a group call (Phase-3 C3b), keeping the SAME room (no reconnect).
  attrs: "call_id", "actor_id", "user_id" (the person to add). The actor must be one of the call's two
  parties (caller_id/callee_id) — either peer may promote → else `{:error, :promote_forbidden}`. Flips
  kind direct→group + status→ongoing, seats BOTH existing parties as `joined` (they're live in the room now),
  and adds the target as an `invited` participant (signaling rings them). Idempotent-friendly: promoting an
  ALREADY-group call just adds the target (the actor must already be a participant). Returns
  `{:ok, %{call, added_user_id, room, type, conversation_id, existing_parties}}`.
  """
  def promote_direct_to_group(attrs) do
    with :ok <- persistence(),
         {:ok, call_id} <- required(attrs, "call_id"),
         {:ok, actor_id} <- required(attrs, "actor_id"),
         {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, call} <- fetch_call(call_id),
         :ok <- ensure_promotable(call),
         :ok <- ensure_call_actor(call, actor_id) do
      do_promote(call, user_id)
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  # ============================================================================================
  # Call links (L1). A reusable link (call_links row) that, on join, spins up a conversation-LESS call
  # (kind="link", conversation_id NULL, link_id=<link>). Registered users only. Approval is L3; L1 lets
  # everyone in. Existing direct/group calls are untouched — these are new functions on new/nullable columns.
  # ============================================================================================

  @doc """
  Create a reusable call link. attrs: "creator_id", "type" ('voice'|'video'), optional "require_approval".
  Generates a collision-safe url-safe id (retried on the tiny chance of a clash). Returns
  `{:ok, %{link: %{id, type, require_approval, active, creator_id}}}`.
  """
  def create_call_link(attrs) do
    with :ok <- persistence(),
         {:ok, creator_id} <- required(attrs, "creator_id"),
         {:ok, type} <- required(attrs, "type") do
      require_approval = truthy(get(attrs, "require_approval"))

      case insert_call_link(creator_id, type, require_approval, 5) do
        {:ok, link} -> {:ok, %{link: link_response(link)}}
        {:error, _} -> {:error, :link_invalid}
      end
    end
  rescue
    _ -> {:error, :link_invalid}
  end

  @doc """
  Fetch an ACTIVE link's metadata (for the join screen). attrs: "link_id". Inactive/missing → `:link_not_found`.
  Returns `{:ok, %{link: link_response}}`.
  """
  def get_call_link(attrs) do
    with :ok <- persistence(),
         {:ok, link_id} <- required(attrs, "link_id"),
         {:ok, link} <- fetch_active_link(link_id) do
      {:ok, %{link: link_response(link)}}
    end
  rescue
    _ -> {:error, :link_not_found}
  end

  @doc """
  Join a call link. attrs: "link_id", "user_id". Loads the active link, then find-or-creates THE ongoing
  `link` call for it (kind="link", conversation_id NULL, link_id set, status "ongoing"; caller_id = the
  first joiner, the effective host). Serialized per-link (row lock) so two simultaneous joiners land in the
  SAME room. APPROVAL (L3a): the host and no-approval links join immediately (status "joined" → `%{status:
  "joined", call, room, type, is_host, require_approval}`). An approval-required NON-host is seated
  `pending_approval` (NO room in the reply — the token 403s until the host approves) → `%{status:
  "pending_approval", call, is_host: false, require_approval: true}`.
  """
  def join_call_link(attrs) do
    with :ok <- persistence(),
         {:ok, link_id} <- required(attrs, "link_id"),
         {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, link} <- fetch_active_link(link_id) do
      now = DateTime.utc_now()

      {:ok, {call, admitted}} =
        Repo.transaction(fn ->
          # Lock the link row → serialize concurrent joins so only the FIRST creates the link call; the rest
          # find the one it created and reuse its room.
          Repo.one(from(l in CallLink, where: l.id == ^link_id, lock: "FOR UPDATE"))
          call = find_or_create_link_call(link, user_id, get(attrs, "app_id"), now)
          admitted = seat_link_joiner(call, link, user_id, now)
          {call, admitted}
        end)

      is_host = user_id == call.caller_id

      if admitted do
        {:ok,
         %{
           status: "joined",
           call: response(call),
           room: call.room_name,
           type: call.type,
           require_approval: link.require_approval,
           is_host: is_host
         }}
      else
        # Pending: no room (the client waits; the token endpoint 403s until approved). call carries call_id
        # so the joiner can send call:link_join_request to the host.
        {:ok,
         %{
           status: "pending_approval",
           call: response(call),
           require_approval: link.require_approval,
           is_host: false
         }}
      end
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  @doc """
  Host admits a pending call-link joiner (L3a). attrs: "call_id", "actor_id" (must be the host = caller_id),
  "user_id". Flips their row to `joined` → the token now authorizes them. Returns
  `{:ok, %{call_id, user_id, status: "joined", room, type}}` so signaling can tell the joiner to connect.
  Non-host actor → `{:error, :not_host}`.
  """
  def approve_link_participant(attrs) do
    with :ok <- persistence(),
         {:ok, call_id} <- required(attrs, "call_id"),
         {:ok, actor_id} <- required(attrs, "actor_id"),
         {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, call} <- fetch_call(call_id),
         :ok <- ensure_host(call, actor_id) do
      upsert_participant_status(call_id, user_id, %{
        status: "joined",
        joined_at: DateTime.utc_now()
      })

      {:ok,
       %{
         call_id: call_id,
         user_id: user_id,
         status: "joined",
         room: call.room_name,
         type: call.type
       }}
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  @doc """
  Host denies a pending call-link joiner (L3a). Same attrs as approve. DELETES their participant row (no row
  → the token fails closed). Returns `{:ok, %{call_id, user_id, status: "denied"}}`. Non-host → `:not_host`.
  """
  def deny_link_participant(attrs) do
    with :ok <- persistence(),
         {:ok, call_id} <- required(attrs, "call_id"),
         {:ok, actor_id} <- required(attrs, "actor_id"),
         {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, call} <- fetch_call(call_id),
         :ok <- ensure_host(call, actor_id) do
      from(p in CallParticipant, where: p.call_id == ^call_id and p.user_id == ^user_id)
      |> Repo.delete_all()

      {:ok, %{call_id: call_id, user_id: user_id, status: "denied"}}
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  # --- link helpers ------------------------------------------------------------------------------

  defp fetch_active_link(link_id) do
    case Repo.get(CallLink, link_id) do
      %CallLink{active: true} = link -> {:ok, link}
      _ -> {:error, :link_not_found}
    end
  end

  # Generate + insert a link, retrying on a PK collision (astronomically unlikely with 8 random bytes).
  defp insert_call_link(_creator_id, _type, _require_approval, 0), do: {:error, :link_collision}

  defp insert_call_link(creator_id, type, require_approval, attempts) do
    %{
      id: generate_link_id(),
      creator_id: creator_id,
      type: type,
      require_approval: require_approval,
      active: true,
      created_at: DateTime.utc_now()
    }
    |> CallLink.create_changeset()
    |> Repo.insert()
    |> case do
      {:ok, link} -> {:ok, link}
      {:error, _changeset} -> insert_call_link(creator_id, type, require_approval, attempts - 1)
    end
  end

  # ~11 url-safe chars (8 random bytes, base64url, no padding).
  defp generate_link_id, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

  defp find_or_create_link_call(%CallLink{id: link_id, type: type}, user_id, app_id, now) do
    case active_link_call(link_id) do
      %Call{} = call -> call
      nil -> insert_link_call!(link_id, type, user_id, app_id, now)
    end
  end

  # Seat a call-link joiner. The host (caller_id) and no-approval links join immediately ("joined"). An
  # approval-required NON-host is RE-GATED to "pending_approval" UNLESS they're CURRENTLY "joined" (an active
  # duplicate join while still in the call → keep them, don't kick their token). A real leave marks the row
  # "left" (server-aware leave), so a leave→rejoin is NOT currently "joined" → re-gated → host must approve
  # again. Returns true = admitted (joined), false = pending.
  defp seat_link_joiner(
         %Call{caller_id: caller_id, id: call_id},
         %CallLink{require_approval: approval},
         user_id,
         now
       ) do
    cond do
      user_id == caller_id or not approval ->
        upsert_participant_status(call_id, user_id, %{status: "joined", joined_at: now})
        true

      currently_joined?(call_id, user_id) ->
        true

      true ->
        upsert_participant_status(call_id, user_id, %{status: "pending_approval", joined_at: nil})
        false
    end
  end

  defp currently_joined?(call_id, user_id) do
    case get_participant_row(call_id, user_id) do
      %CallParticipant{status: "joined"} -> true
      _ -> false
    end
  end

  # The host of a link call is its caller_id (the first joiner). Only the host may approve/deny.
  defp ensure_host(%Call{caller_id: caller_id}, actor_id) do
    if is_binary(caller_id) and actor_id == caller_id, do: :ok, else: {:error, :not_host}
  end

  defp active_link_call(link_id) do
    from(c in Call,
      where: c.kind == "link" and c.link_id == ^link_id and c.status in ["ringing", "ongoing"],
      order_by: [desc: c.created_at],
      limit: 1
    )
    |> Repo.one()
  end

  defp insert_link_call!(link_id, type, caller_id, app_id, now) do
    id = Ecto.UUID.generate()

    %{
      id: id,
      room_name: "call-" <> id,
      app_id: app_id,
      kind: "link",
      caller_id: caller_id,
      callee_id: nil,
      conversation_id: nil,
      link_id: link_id,
      type: type,
      status: "ongoing",
      created_at: now
    }
    |> Call.create_changeset()
    |> Repo.insert!()
  end

  defp link_response(%CallLink{} = link) do
    %{
      id: link.id,
      type: link.type,
      require_approval: link.require_approval,
      active: link.active,
      creator_id: link.creator_id
    }
  end

  defp truthy(v), do: v in [true, "true", "1", "yes"]

  # --- group helpers -----------------------------------------------------------------------------

  defp insert_call!(id, app_id, initiator_id, conversation_id, type, now) do
    %{
      id: id,
      room_name: "call-" <> id,
      app_id: app_id,
      kind: "group",
      caller_id: initiator_id,
      callee_id: nil,
      conversation_id: conversation_id,
      type: type,
      status: "ringing",
      created_at: now
    }
    |> Call.create_changeset()
    |> Repo.insert!()
  end

  defp insert_participant!(call_id, user_id, status, created_at, joined_at) do
    %{
      call_id: call_id,
      user_id: user_id,
      status: status,
      created_at: created_at,
      joined_at: joined_at
    }
    |> CallParticipant.create_changeset()
    |> Repo.insert!()
  end

  defp upsert_participant_status(call_id, user_id, patch) do
    case get_participant_row(call_id, user_id) do
      nil ->
        %{call_id: call_id, user_id: user_id, created_at: DateTime.utc_now()}
        |> Map.merge(patch)
        |> CallParticipant.create_changeset()
        |> Repo.insert()

      %CallParticipant{} = participant ->
        participant
        |> CallParticipant.status_changeset(patch)
        |> Repo.update()
    end
  end

  defp get_participant_row(call_id, user_id) do
    Repo.get_by(CallParticipant, call_id: call_id, user_id: user_id)
  end

  defp list_participants(call_id) do
    from(p in CallParticipant, where: p.call_id == ^call_id, order_by: [asc: p.created_at])
    |> Repo.all()
    |> Enum.map(&participant_response/1)
  end

  # "adhoc" (116) is an N-party call exactly like "group" for every lifecycle purpose — join,
  # add, decline, leave, timeout — differing only in WHERE membership comes from (participant rows
  # alone; there is no conversation).
  defp fetch_group_call(call_id) do
    case Repo.get(Call, call_id) do
      %Call{kind: kind} = call when kind in ["group", "adhoc"] -> {:ok, call}
      %Call{} -> {:error, :not_a_group_call}
      nil -> {:error, :call_not_found}
    end
  end

  # Leave accepts a GROUP or a LINK call (both are N-party calls with participant rows + close-when-empty).
  # Only leave_group_call uses this — the other group-only functions keep the stricter fetch_group_call.
  defp fetch_group_or_link_call(call_id) do
    case Repo.get(Call, call_id) do
      %Call{kind: kind} = call when kind in ["group", "link", "adhoc"] -> {:ok, call}
      %Call{} -> {:error, :not_a_group_call}
      nil -> {:error, :call_not_found}
    end
  end

  # Kind-agnostic fetch (promote reads a DIRECT call, which fetch_group_call would reject).
  defp fetch_call(call_id) do
    case Repo.get(Call, call_id) do
      %Call{} = call -> {:ok, call}
      nil -> {:error, :call_not_found}
    end
  end

  # A call is promotable when it's LIVE: a direct call that's been answered ("accepted"), or an already-group
  # call that's still ringing/ongoing (idempotent re-promote). Anything else → not promotable.
  defp ensure_promotable(%Call{kind: "group", status: status})
       when status in ["ringing", "ongoing"],
       do: :ok

  defp ensure_promotable(%Call{kind: "direct", status: "accepted"}), do: :ok
  defp ensure_promotable(_), do: {:error, :call_not_promotable}

  # The actor must belong to the call: a direct call's caller/callee (either peer may promote), or — for an
  # already-group call — an existing participant. Else forbidden.
  defp ensure_call_actor(%Call{kind: "group", id: id}, actor_id) do
    if has_participant_row?(id, actor_id), do: :ok, else: {:error, :promote_forbidden}
  end

  defp ensure_call_actor(%Call{caller_id: caller_id, callee_id: callee_id}, actor_id) do
    if actor_id == caller_id or actor_id == callee_id, do: :ok, else: {:error, :promote_forbidden}
  end

  # An already-group call: just add the target (both parties are already seated). Keeps promote idempotent
  # if two peers race to promote or a client re-fires.
  defp do_promote(%Call{kind: "group"} = call, user_id) do
    ensure_invited_participant(call.id, user_id)
    {:ok, promote_result(call, user_id)}
  end

  # A direct call → flip to group + seat both parties joined + invite the target, in one transaction.
  defp do_promote(%Call{} = call, user_id) do
    caller_id = call.caller_id
    callee_id = call.callee_id
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      case call |> Call.promote_changeset(%{kind: "group", status: "ongoing"}) |> Repo.update() do
        {:ok, promoted} ->
          upsert_participant_status(call.id, caller_id, %{status: "joined", joined_at: now})

          if is_binary(callee_id),
            do: upsert_participant_status(call.id, callee_id, %{status: "joined", joined_at: now})

          ensure_invited_participant(call.id, user_id)
          promoted

        {:error, _changeset} ->
          Repo.rollback(:promote_invalid)
      end
    end)
    |> case do
      {:ok, promoted} -> {:ok, promote_result(promoted, user_id)}
      {:error, _reason} -> {:error, :call_invalid}
    end
  end

  defp promote_result(%Call{} = call, user_id) do
    %{
      call: response(call),
      added_user_id: user_id,
      room: call.room_name,
      type: call.type,
      conversation_id: call.conversation_id,
      existing_parties: Enum.filter([call.caller_id, call.callee_id], &is_binary/1)
    }
  end

  defp ensure_joinable(%{status: status}) when status in ["ringing", "ongoing"], do: :ok
  defp ensure_joinable(_), do: {:error, :call_not_joinable}

  defp ensure_member(members, user_id) do
    if Enum.any?(members, &(&1.user_id == user_id)), do: :ok, else: {:error, :not_a_member}
  end

  # Join is allowed for a conversation member (normal ring / late-join) OR anyone who already holds a
  # participant row for this call (an added non-member — C2). A non-member with no row is rejected.
  defp ensure_member_or_participant(members, call_id, user_id) do
    cond do
      Enum.any?(members, &(&1.user_id == user_id)) -> :ok
      has_participant_row?(call_id, user_id) -> :ok
      true -> {:error, :not_a_member}
    end
  end

  # Add-authorization, by kind. GROUP: the conversation-derived rule below, unchanged. ADHOC (116):
  # the actor must hold a participant row on THIS call (the promote group-arm precedent), and the
  # TARGET runs the SAME exists/active/same-app/not-blocked gate as create — which is where
  # resolve_add_target's raw-user_id tenant gap is closed for this kind. The tenant is the CALL row's
  # app_id (stamped from the creator's socket session); a nil app_id fails the gate closed.
  defp authorize_add(%Call{kind: "adhoc"} = call, actor_id, user_id) do
    cond do
      not has_participant_row?(call.id, actor_id) ->
        {:error, :call_add_forbidden}

      is_nil(call.app_id) ->
        {:error, :invalid_targets}

      true ->
        with {:ok, targets} <- normalize_adhoc_targets([user_id], actor_id) do
          authorize_adhoc_targets(targets, actor_id, call.app_id)
        end
    end
  end

  defp authorize_add(%Call{} = call, actor_id, _user_id) do
    members = ParticipantStore.list_active_participants(call.conversation_id)
    ensure_can_add(call.conversation_id, members, actor_id)
  end

  # A conversationless call has NO conversation members; nil must not reach Ecto (it raises).
  defp conversation_members(nil), do: []

  defp conversation_members(conversation_id),
    do: ParticipantStore.list_active_participants(conversation_id)

  # Actor authorization for adding a participant — the SAME rule as starting a call (active member; under
  # admins_only, owner/admin). Any failure collapses to :call_add_forbidden (signaling maps it to a code).
  defp ensure_can_add(conversation_id, members, actor_id) do
    with :ok <- ensure_member(members, actor_id),
         :ok <- ensure_can_start(conversation_id, members, actor_id) do
      :ok
    else
      _ -> {:error, :call_add_forbidden}
    end
  end

  # Idempotent invite: no row → insert `invited`; a live invited/joined row → no-op (re-adding someone
  # already in is a no-op); a spent declined/left/missed row → flip back to `invited` so they ring again.
  defp ensure_invited_participant(call_id, user_id) do
    case get_participant_row(call_id, user_id) do
      nil ->
        insert_participant!(call_id, user_id, "invited", DateTime.utc_now(), nil)

      %CallParticipant{status: status} when status in ["invited", "joined"] ->
        :ok

      %CallParticipant{} = participant ->
        participant |> CallParticipant.status_changeset(%{status: "invited"}) |> Repo.update()
    end
  end

  # Does (call_id, user_id) have ANY participant row? The raw predicate behind join/promote authorization
  # (a member/added participant may join regardless of status). NOT used by the token.
  defp has_participant_row?(call_id, user_id) do
    from(p in CallParticipant, where: p.call_id == ^call_id and p.user_id == ^user_id, limit: 1)
    |> Repo.exists?()
  end

  # TOKEN predicate: a participant row that is NOT `pending_approval`. A call-link joiner waiting for the host
  # has only a pending row → not authorized (token 403) until the host approves and the row flips to `joined`.
  defp authorized_participant?(call_id, user_id) do
    from(p in CallParticipant,
      where: p.call_id == ^call_id and p.user_id == ^user_id and p.status != "pending_approval",
      limit: 1
    )
    |> Repo.exists?()
  end

  defp ensure_can_start(conversation_id, members, initiator_id) do
    case call_start_permission(conversation_id) do
      "admins_only" ->
        if member_role(members, initiator_id) in ["owner", "admin"],
          do: :ok,
          else: {:error, :call_start_forbidden}

      _ ->
        :ok
    end
  end

  defp call_start_permission(conversation_id) do
    case ConversationSettingsStore.get_settings(conversation_id) do
      %{call_start_permission: perm} when is_binary(perm) -> perm
      _ -> "everyone"
    end
  end

  defp member_role(members, user_id) do
    case Enum.find(members, &(&1.user_id == user_id)) do
      %{role: role} when is_binary(role) -> role
      _ -> "member"
    end
  end

  # THE single close rule (reused by decline / leave / ring-timeout). A ringing/ongoing group call ends the
  # moment NOBODY is `joined` — regardless of pending invites (a stale ring shouldn't keep an EMPTY call
  # "ongoing", which would leave the C1 "Join" banner up on a call nobody's in). Terminal status: `ended`
  # if anyone OTHER than the initiator ever joined (a real multi-party call), else `missed` (initiator-only
  # or nobody answered → the missed-group-call pill). Already-terminal calls pass through unchanged.
  defp maybe_close_call(%Call{status: status} = call) when status in ["ringing", "ongoing"] do
    counts = participant_status_counts(call.id)

    if Map.get(counts, "joined", 0) == 0 do
      terminal = if anyone_but_initiator_joined?(call), do: "ended", else: "missed"

      {:ok, updated} =
        call
        |> Call.status_changeset(%{status: terminal, ended_at: DateTime.utc_now()})
        |> Repo.update()

      updated
    else
      call
    end
  end

  defp maybe_close_call(call), do: call

  # Did anyone OTHER than the initiator (caller_id) ever join (joined_at set)? Distinguishes a real
  # multi-party call (→ "ended") from an initiator-only / nobody-answered call (→ "missed" + pill).
  defp anyone_but_initiator_joined?(%Call{id: call_id, caller_id: caller_id}) do
    from(p in CallParticipant,
      where: p.call_id == ^call_id and p.user_id != ^caller_id and not is_nil(p.joined_at),
      limit: 1
    )
    |> Repo.exists?()
  end

  defp participant_status_counts(call_id) do
    from(p in CallParticipant,
      where: p.call_id == ^call_id,
      group_by: p.status,
      select: {p.status, count(p.user_id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # A lifecycle transition: fetch the call, apply the status/timestamp patch, and (when the transition has a
  # webhook event) emit it.
  #
  # TRANSACTIONAL OUTBOX: the emit runs in the SAME transaction as the status update, mirroring
  # conversation.created (conversations.ex). A webhook for a call that never actually transitioned would be a
  # lie to the integrator's server, so the two commit together or not at all. The converse also holds — the
  # outbox INSERT raises on failure, which rolls the status change back — which is the price of atomicity and
  # the same trade the conversation path already makes.
  #
  # OPTIONAL ATOMIC PRECONDITION: an `"expected_status"` in attrs makes the transition conditional — the row
  # is locked FOR UPDATE and the patch applies ONLY if the CURRENT status equals it, else `:call_conflict`.
  # This closes a check-then-act race: without it, two concurrent accepts both read "ringing" and both emit
  # call.started, and a cancel racing an accept can un-end the call. The lock serializes concurrent
  # transitions on the SAME call, and the source-status guard is re-checked while holding it. Callers that do
  # NOT pass expected_status (the socket signaling + group-call paths) keep the exact prior behaviour — plain
  # unlocked get + unconditional patch — so this is a hardening of the /v1 answer path, not a state-machine
  # change for the existing callers.
  defp transition(attrs, patch, webhook_event) do
    with :ok <- persistence(),
         {:ok, call_id} <- required(attrs, "call_id") do
      expected = get(attrs, "expected_status")

      Repo.transaction(fn ->
        case load_for_transition(call_id, expected) do
          nil ->
            Repo.rollback(:call_not_found)

          # The precondition was requested but the current status doesn't match (already answered / ended /
          # cancelled by the time we hold the lock) → refuse without touching the row or re-emitting anything.
          {:conflict, _call} ->
            Repo.rollback(:call_conflict)

          {:ok, call} ->
            case call |> Call.status_changeset(patch) |> Repo.update() do
              {:ok, updated} ->
                emit_call_webhook(webhook_event, updated)
                response(updated)

              {:error, _changeset} ->
                Repo.rollback(:call_invalid)
            end
        end
      end)
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  # No precondition (socket / group callers): the original plain fetch, unchanged.
  defp load_for_transition(call_id, nil) do
    case Repo.get(Call, call_id) do
      nil -> nil
      %Call{} = call -> {:ok, call}
    end
  end

  # Precondition requested (the /v1 answer path): lock the row so a concurrent transition blocks, then
  # re-check the source status while holding the lock.
  defp load_for_transition(call_id, expected) when is_binary(expected) do
    query = from(c in Call, where: c.id == ^call_id, lock: "FOR UPDATE")

    case Repo.one(query) do
      nil -> nil
      %Call{status: ^expected} = call -> {:ok, call}
      %Call{} = call -> {:conflict, call}
    end
  end

  defp emit_call_webhook(nil, _call), do: :ok

  defp emit_call_webhook(event_type, %Call{} = call) do
    case call_identities(call) do
      {:ok, app_id, caller_external_id, callee_external_id} ->
        SharedInfra.WebhookOutbox.emit(
          Repo,
          app_id,
          event_type,
          call_webhook_payload(call, caller_external_id, callee_external_id)
        )

      :error ->
        # No resolvable tenant (a user row vanished) → no webhook. We do NOT fail the call transition over
        # it: hanging up must still work. An unattributable event is dropped rather than sent to the wrong app.
        :ok
    end
  end

  # THE TENANT + IDENTITY SOURCE. `calls` has NO app_id column, and conversation_id is NULL for a link call
  # (069) — so the conversation cannot be the tenant source without silently dropping every link call. The
  # caller's `users_auth` row can: app_id is NOT NULL there, and it carries the external_id in the same row.
  # Both parties are always in the same app (the socket is app-scoped), so caller.app_id IS the call's tenant.
  defp call_identities(%Call{caller_id: caller_id, callee_id: callee_id})
       when is_binary(caller_id) and is_binary(callee_id) do
    case Repo.query(
           """
           SELECT caller.app_id::text, caller.external_id, callee.external_id
           FROM users_auth caller
           JOIN users_auth callee ON callee.id = $2::text::uuid
           WHERE caller.id = $1::text::uuid
           """,
           [caller_id, callee_id]
         ) do
      {:ok, %{rows: [[app_id, caller_external_id, callee_external_id]]}} when is_binary(app_id) ->
        {:ok, app_id, caller_external_id, callee_external_id}

      _ ->
        :error
    end
  end

  defp call_identities(_call), do: :error

  # METADATA ONLY. No room_name, no LiveKit token, no media, no message content — an integrator's server gets
  # the fact of the call, never the means to join it.
  defp call_webhook_payload(%Call{} = call, caller_external_id, callee_external_id) do
    %{
      call_id: call.id,
      type: call.type,
      kind: call.kind || "direct",
      caller_external_id: caller_external_id,
      callee_external_id: callee_external_id,
      conversation_id: call.conversation_id,
      started_at: iso8601(call.answered_at),
      ended_at: iso8601(call.ended_at),
      # Only a call that was actually ANSWERED has a duration. A missed/declined call was never connected, so
      # it gets nil rather than a misleading 0.
      duration_seconds: duration_seconds(call),
      reason: call.status
    }
  end

  defp duration_seconds(%Call{
         answered_at: %DateTime{} = answered,
         ended_at: %DateTime{} = ended
       }),
       do: max(DateTime.diff(ended, answered, :second), 0)

  defp duration_seconds(_call), do: nil

  defp response(%Call{} = call) do
    %{
      id: call.id,
      room_name: call.room_name,
      # Old rows (pre-068) load as "direct" (column default); new group calls carry "group".
      kind: call.kind || "direct",
      app_id: call.app_id,
      caller_id: call.caller_id,
      callee_id: call.callee_id,
      conversation_id: call.conversation_id,
      type: call.type,
      status: call.status,
      created_at: iso8601(call.created_at),
      answered_at: iso8601(call.answered_at),
      ended_at: iso8601(call.ended_at),
      # nil when the call never connected — the /v1 webhook's recorded "nil, not a misleading 0"; the
      # first-party list surface maps nil → 0 at presentation (its recorded contract) — one raw truth here.
      duration_seconds: duration_seconds(call),
      # E2EE (111). `e2ee` is the durable capability bit (survives the end-of-call scrub, so history
      # can draw a lock); `e2ee_accepted` is the agreed mode; `e2ee_offer` carries the sealed
      # envelopes and is nil once the call is over. The server never reads inside an envelope.
      e2ee: call.e2ee || false,
      e2ee_accepted: call.e2ee_accepted,
      e2ee_offer: call.e2ee_offer
    }
  end

  defp participant_response(nil), do: nil

  defp participant_response(%CallParticipant{} = p) do
    %{
      call_id: p.call_id,
      user_id: p.user_id,
      status: p.status,
      joined_at: iso8601(p.joined_at),
      left_at: iso8601(p.left_at),
      created_at: iso8601(p.created_at)
    }
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # ---- E2EE call-key offer (111 / E2EE_FRAME.md §calls) -------------------------------------------
  #
  # THE SERVER VALIDATES SHAPE ONLY AND NEVER LOOKS INSIDE AN ENVELOPE. It cannot: the envelopes are
  # anonymous sealed boxes to device X25519 keys the server holds only the PUBLIC half of. What it can
  # check is that the blob is well-formed and addressed to devices that actually belong to the two
  # parties — a foreign device_id is either a bug or an attempt to have us relay a key to an outsider.
  #
  # It also never enforces the MODE. Whether the call runs encrypted is an agreement between the two
  # clients (offer + accept flag); the server only carries the bits. A missing offer is not an error,
  # it is an old client, and the call proceeds exactly as it did before this slice.
  @e2ee_max_envelopes 20
  @e2ee_max_bytes 32 * 1024

  defp validate_e2ee_offer(nil, _caller_id, _callee_id), do: {:ok, nil}

  defp validate_e2ee_offer(offer, caller_id, callee_id) when is_map(offer) do
    envelopes = Map.get(offer, "envelopes") || Map.get(offer, :envelopes)

    with true <- version_one?(offer) || {:error, :call_invalid_e2ee_offer},
         true <- nonempty_string?(sender_device(offer)) || {:error, :call_invalid_e2ee_offer},
         true <- valid_envelopes?(envelopes) || {:error, :call_invalid_e2ee_offer},
         true <-
           length(envelopes) <= @e2ee_max_envelopes || {:error, :call_invalid_e2ee_offer},
         true <-
           byte_size(Jason.encode!(offer)) <= @e2ee_max_bytes ||
             {:error, :call_invalid_e2ee_offer},
         true <-
           envelope_devices_belong?(envelopes, caller_id, callee_id) ||
             {:error, :call_invalid_e2ee_offer} do
      # Stored VERBATIM — normalising it would change bytes the clients may hash or compare.
      {:ok, offer}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_e2ee_offer(_offer, _caller_id, _callee_id), do: {:error, :call_invalid_e2ee_offer}

  defp version_one?(offer), do: (Map.get(offer, "v") || Map.get(offer, :v)) == 1

  defp sender_device(offer),
    do: Map.get(offer, "sender_device_id") || Map.get(offer, :sender_device_id)

  defp nonempty_string?(value), do: is_binary(value) and value != ""

  defp valid_envelopes?(envelopes) do
    is_list(envelopes) and envelopes != [] and
      Enum.all?(envelopes, fn envelope ->
        is_map(envelope) and nonempty_string?(envelope_device(envelope)) and
          valid_base64?(envelope_blob(envelope))
      end)
  end

  defp envelope_device(envelope),
    do: Map.get(envelope, "device_id") || Map.get(envelope, :device_id)

  defp envelope_blob(envelope),
    do: Map.get(envelope, "envelope_b64") || Map.get(envelope, :envelope_b64)

  # Standard padded base64 (RFC 4648) — the same variant every other _b64 field in the E2EE spec uses.
  defp valid_base64?(value) do
    nonempty_string?(value) and match?({:ok, _}, Base.decode64(value))
  end

  # Every addressed device must be a LIVE device of the caller or the callee. Mirrors the sealed
  # MESSAGE rule (MessageService.Messages.recipients_are_member_devices?/2): liveness is a
  # non-revoked device_sessions row, and a device is allowed even if it has not uploaded keys yet.
  defp envelope_devices_belong?(envelopes, caller_id, callee_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT ds.device_id FROM device_sessions ds " <>
          "WHERE ds.revoked_at IS NULL AND ds.user_id IN ($1::text::uuid, $2::text::uuid)",
        [to_string(caller_id), to_string(callee_id)]
      )

    allowed = MapSet.new(rows, fn [device_id] -> device_id end)
    Enum.all?(envelopes, &MapSet.member?(allowed, envelope_device(&1)))
  rescue
    _ -> false
  end

  defp required(attrs, key) do
    case get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :call_invalid}
    end
  end

  defp get(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))

  # Presence-preserving lookup for values where `false` is meaningful (see mark_answered/1).
  defp fetch_either(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, String.to_atom(key))
    end
  end

  defp limit(attrs) do
    case get(attrs, "limit") do
      n when is_integer(n) and n > 0 and n <= 200 -> n
      n when is_binary(n) -> String.to_integer(n)
      _ -> 50
    end
  rescue
    _ -> 50
  end

  defp persistence do
    if Application.get_env(:conversation_service, :conversation_persistence, false) ||
         System.get_env("CONVERSATION_DB_BACKED") in ["true", "1", "yes"] do
      :ok
    else
      {:error, :call_unavailable}
    end
  end
end
