defmodule ConversationService.Conversations do
  @moduledoc """
  Conversation metadata boundary.
  """

  alias ConversationService.ConversationStore
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

  defp admin_conv_filter(attrs) do
    case attrs["q"] || attrs[:q] do
      q when is_binary(q) and q != "" ->
        {"WHERE (c.title ILIKE $1 OR c.id::text ILIKE $1)", ["%#{q}%"]}

      _ ->
        {"", []}
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
              "ORDER BY c.updated_at DESC LIMIT 100"

          %Postgrex.Result{rows: rows} = Repo.query!(sql, [uuid_bin])

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

      {:ok, conversation_detail_response(conversation, participants)}
    end
  rescue
    Ecto.Query.CastError -> {:error, :conversation_invalid}
  end

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

  defp conversation_detail_response(conversation, participants) do
    %{
      conversation_id: conversation.id,
      tenant_id: conversation.tenant_id,
      # The app (tenant) that owns this conversation — lets the /v1 layer reject cross-tenant access
      # (a conversation not in the caller's app_id → 404).
      app_id: conversation.app_id,
      type: conversation.type,
      title: conversation.title,
      created_by: conversation.created_by,
      participants: participants
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
      conversations =
        user_id
        |> ConversationStore.list_conversations_for_user()
        |> Enum.map(&conversation_list_item/1)

      {:ok, %{conversations: conversations}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :conversation_invalid}
  end

  defp conversation_list_item(conversation) do
    %{
      conversation_id: conversation.id,
      type: conversation.type,
      title: conversation.title,
      last_message_preview: nil,
      unread_count: 0,
      updated_at: iso8601(conversation.updated_at)
    }
  end

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

          {:ok, response}

        {:ok, response, :existing} ->
          {:ok, response}

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
             add_initial_participants(conversation.id, created_by, participant_user_ids, now) do
        # TRANSACTIONAL OUTBOX: emit conversation.created in the SAME transaction (same Repo) as the
        # conversation + participant inserts, scoped to the conversation's app_id. Atomic with the write.
        SharedInfra.WebhookOutbox.emit(
          Repo,
          conversation.app_id,
          "conversation.created",
          conversation_event(conversation, participant_user_ids)
        )

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

  defp conversation_event(conversation, participant_user_ids) do
    %{
      "conversation_id" => conversation.id,
      "type" => conversation.type,
      "title" => conversation.title,
      "created_by" => conversation.created_by,
      "participant_user_ids" => participant_user_ids
    }
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
