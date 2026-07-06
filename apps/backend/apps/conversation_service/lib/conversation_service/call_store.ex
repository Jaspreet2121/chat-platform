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
  alias ConversationService.Schemas.CallParticipant

  @doc """
  Create a ringing call. attrs: "caller_id", "callee_id", "type" ('voice'|'video'), optional
  "conversation_id". Generates the id + a unique LiveKit room_name. Returns `{:ok, call}`.
  """
  def create_call(attrs) do
    with :ok <- persistence(),
         {:ok, caller_id} <- required(attrs, "caller_id"),
         {:ok, callee_id} <- required(attrs, "callee_id"),
         {:ok, type} <- required(attrs, "type") do
      id = Ecto.UUID.generate()

      changeset =
        Call.create_changeset(%{
          id: id,
          room_name: "call-" <> id,
          caller_id: caller_id,
          callee_id: callee_id,
          conversation_id: get(attrs, "conversation_id"),
          type: type,
          status: "ringing",
          created_at: DateTime.utc_now()
        })

      case Repo.insert(changeset) do
        {:ok, call} -> {:ok, response(call)}
        {:error, _changeset} -> {:error, :call_invalid}
      end
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  @doc "Caller answered → accepted + answered_at. attrs: \"call_id\"."
  def mark_answered(attrs),
    do: transition(attrs, %{status: "accepted", answered_at: DateTime.utc_now()})

  @doc "Callee rejected → declined. attrs: \"call_id\"."
  def mark_declined(attrs),
    do: transition(attrs, %{status: "declined", ended_at: DateTime.utc_now()})

  @doc "Never answered (timeout / caller cancel while ringing) → missed. attrs: \"call_id\"."
  def mark_missed(attrs),
    do: transition(attrs, %{status: "missed", ended_at: DateTime.utc_now()})

  @doc "Call finished (hang up) → ended. attrs: \"call_id\"."
  def mark_ended(attrs),
    do: transition(attrs, %{status: "ended", ended_at: DateTime.utc_now()})

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
  optional "limit" (default 50). → {:ok, %{calls: [...]}}.
  """
  def list_calls_for_user(attrs) do
    with :ok <- persistence(),
         {:ok, user_id} <- required(attrs, "user_id") do
      limit = limit(attrs)

      # 1-on-1 rows: matched by caller/callee EXACTLY as before. Group rows: added via a call_participants
      # membership subquery. distinct so a row can't repeat. Old 1-on-1 history is unchanged.
      participant_calls = from(p in CallParticipant, where: p.user_id == ^user_id, select: p.call_id)

      calls =
        from(c in Call,
          where:
            c.caller_id == ^user_id or c.callee_id == ^user_id or c.id in subquery(participant_calls),
          distinct: true,
          order_by: [desc: c.created_at],
          limit: ^limit
        )
        |> Repo.all()
        |> Enum.map(&response/1)

      {:ok, %{calls: calls}}
    end
  rescue
    _ -> {:error, :call_invalid}
  end

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

      Repo.transaction(fn ->
        call = insert_call!(id, initiator_id, conversation_id, type, now)
        insert_participant!(id, initiator_id, "joined", now, now)
        Enum.each(others, fn uid -> insert_participant!(id, uid, "invited", now, nil) end)
        call
      end)
      |> case do
        {:ok, call} ->
          {:ok,
           %{call: response(call), participants: list_participants(id), member_ids: others}}

        {:error, _reason} ->
          {:error, :call_invalid}
      end
    end
  rescue
    _ -> {:error, :call_invalid}
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
         members <- ParticipantStore.list_active_participants(call.conversation_id),
         :ok <- ensure_member(members, user_id) do
      now = DateTime.utc_now()
      upsert_participant_status(call_id, user_id, %{status: "joined", joined_at: now})

      call =
        if call.status == "ringing" do
          {:ok, updated} = call |> Call.status_changeset(%{status: "ongoing"}) |> Repo.update()
          updated
        else
          call
        end

      {:ok, %{call: response(call), participant: participant_response(get_participant_row(call_id, user_id))}}
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
      {:ok, %{call: response(call), participant: participant_response(get_participant_row(call_id, user_id))}}
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  @doc "Leave a group call. attrs: \"call_id\", \"user_id\". Closes the call when nobody remains."
  def leave_group_call(attrs) do
    with :ok <- persistence(),
         {:ok, call_id} <- required(attrs, "call_id"),
         {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, call} <- fetch_group_call(call_id) do
      now = DateTime.utc_now()
      upsert_participant_status(call_id, user_id, %{status: "left", left_at: now})
      call = maybe_close_call(call)
      {:ok, %{call: response(call), participant: participant_response(get_participant_row(call_id, user_id))}}
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

  # --- group helpers -----------------------------------------------------------------------------

  defp insert_call!(id, initiator_id, conversation_id, type, now) do
    %{
      id: id,
      room_name: "call-" <> id,
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
    %{call_id: call_id, user_id: user_id, status: status, created_at: created_at, joined_at: joined_at}
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

  defp fetch_group_call(call_id) do
    case Repo.get(Call, call_id) do
      %Call{kind: "group"} = call -> {:ok, call}
      %Call{} -> {:error, :not_a_group_call}
      nil -> {:error, :call_not_found}
    end
  end

  defp ensure_joinable(%{status: status}) when status in ["ringing", "ongoing"], do: :ok
  defp ensure_joinable(_), do: {:error, :call_not_joinable}

  defp ensure_member(members, user_id) do
    if Enum.any?(members, &(&1.user_id == user_id)), do: :ok, else: {:error, :not_a_member}
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

  # THE single close rule (reused by decline / leave / ring-timeout). A ringing/ongoing group call ends
  # once NOBODY is `joined` AND NOBODY is still `invited` (nobody active, nobody pending). Terminal status:
  # `ended` if it ever went `ongoing`, else `missed` (it only ever rang). Already-terminal calls pass
  # through unchanged. (A lone joined initiator or any pending invite keeps the call open — the ring-timeout
  # clears stale invites, which then lets this rule close the call.)
  defp maybe_close_call(%Call{status: status} = call) when status in ["ringing", "ongoing"] do
    counts = participant_status_counts(call.id)

    if Map.get(counts, "joined", 0) == 0 and Map.get(counts, "invited", 0) == 0 do
      terminal = if status == "ongoing", do: "ended", else: "missed"
      {:ok, updated} = call |> Call.status_changeset(%{status: terminal, ended_at: DateTime.utc_now()}) |> Repo.update()
      updated
    else
      call
    end
  end

  defp maybe_close_call(call), do: call

  defp participant_status_counts(call_id) do
    from(p in CallParticipant,
      where: p.call_id == ^call_id,
      group_by: p.status,
      select: {p.status, count(p.user_id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # A lifecycle transition: fetch the call, apply the status/timestamp patch.
  defp transition(attrs, patch) do
    with :ok <- persistence(),
         {:ok, call_id} <- required(attrs, "call_id") do
      case Repo.get(Call, call_id) do
        nil ->
          {:error, :call_not_found}

        %Call{} = call ->
          call
          |> Call.status_changeset(patch)
          |> Repo.update()
          |> case do
            {:ok, updated} -> {:ok, response(updated)}
            {:error, _changeset} -> {:error, :call_invalid}
          end
      end
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  defp response(%Call{} = call) do
    %{
      id: call.id,
      room_name: call.room_name,
      # Old rows (pre-068) load as "direct" (column default); new group calls carry "group".
      kind: call.kind || "direct",
      caller_id: call.caller_id,
      callee_id: call.callee_id,
      conversation_id: call.conversation_id,
      type: call.type,
      status: call.status,
      created_at: iso8601(call.created_at),
      answered_at: iso8601(call.answered_at),
      ended_at: iso8601(call.ended_at)
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

  defp required(attrs, key) do
    case get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :call_invalid}
    end
  end

  defp get(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))

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
