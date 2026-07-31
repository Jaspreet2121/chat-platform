defmodule ApiGatewayWeb.V1.ConversationController do
  @moduledoc """
  Public `/v1` conversation create + read + list — scoped to the authenticated app_id. Participants are the
  integrator's external end-user ids, resolved-or-created within this app. Reuses conversation_service's
  create/find_or_create_direct (direct chats stay idempotent per pair per app).

  Authorization (via `ConversationAuthz.authorize_conversation/2`): an app (secret-key) actor reads within
  its tenant; an end-user (JWT) actor must additionally be an active participant. Any failure → 404 (no
  existence reveal, never 403).
  """

  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse
  alias ApiGatewayWeb.V1.ConversationAuthz

  # GET /v1/conversations — the CALLER'S OWN conversations, newest-activity first. End-user (JWT) actor
  # only: the list is membership-scoped via list_conversations (keyed by user_id, which is app-scoped, so
  # transitively this app's conversations only). A secret-key/app actor → 403 v1.end_user_only (a
  # tenant-wide admin list is a separate, paginated design — not improvised here). `limit` (default 30,
  # cap 100) trims the ordered set; a cursor is deferred (the list service returns the full ordered set).
  def index(conn, params) do
    case conn.assigns[:v1_user_id] do
      user_id when is_binary(user_id) and user_id != "" ->
        case SharedInfra.ConversationClient.list_conversations(%{"user_id" => user_id}) do
          {:ok, %{conversations: conversations}} ->
            json(conn, %{conversations: present_list(conversations, list_limit(params))})

          {:error, :conversation_unavailable} ->
            ErrorResponse.service_unavailable(conn, "v1.unavailable")

          _ ->
            ErrorResponse.invalid_request(conn, "v1.invalid_request")
        end

      _ ->
        ErrorResponse.forbidden(
          conn,
          "v1.end_user_only",
          "This endpoint requires an end-user token"
        )
    end
  end

  # GET /v1/conversations/:id — authorized read. App actor: tenant-scoped; end-user: must be a participant;
  # a cross-tenant / unknown / non-member id all return 404. The body is ALWAYS the tenant summary
  # (get_conversation_app) so the response shape is identical for both actors and never leaks the internal
  # participant user_ids that get_conversation's detail shape carries.
  def show(conn, %{"id" => conversation_id}) do
    app_id = conn.assigns.v1_app_id

    with {:ok, _authorized} <- ConversationAuthz.authorize_conversation(conn, conversation_id),
         {:ok, summary} <-
           SharedInfra.ConversationClient.get_conversation_app(%{
             "conversation_id" => conversation_id,
             "app_id" => app_id
           }) do
      json(conn, summary)
    else
      _ -> ErrorResponse.not_found(conn, "v1.not_found", "Not found")
    end
  end

  @doc """
  PATCH /v1/conversations/:id — rename a GROUP.

  Writes `group_profiles.name`, the single source of truth for a group's name (the inbox and the detail view
  both resolve through it), by reusing the existing owner/admin-gated `set_group_profile` — no second write
  path, and therefore no second authz rule to keep in step.

  END-USER token only (same rule as receipts): the rename is owner/admin-gated INSIDE the conversation
  service, and an app-actor token has no user to authorize. A DIRECT chat has no name to set — the service
  rejects it (`ensure_group`), surfaced here as 422.
  """
  def update(conn, %{"id" => conversation_id} = params) do
    with {:ok, user_id} <- require_end_user(conn),
         {:ok, _authorized} <- ConversationAuthz.authorize_conversation(conn, conversation_id),
         {:ok, title} <- fetch_title(params),
         {:ok, response} <-
           SharedInfra.ConversationClient.set_group_profile(%{
             "conversation_id" => conversation_id,
             "actor_user_id" => user_id,
             "name" => title
           }) do
      # Every participant's inbox row carries the title — push the new one live.
      ApiGatewayWeb.ConversationBroadcast.broadcast_updated(conversation_id, user_id, :title)

      json(conn, %{conversation_id: conversation_id, title: Map.get(response, :name) || title})
    else
      {:error, :end_user_only} ->
        ErrorResponse.forbidden(
          conn,
          "v1.end_user_only",
          "This endpoint requires an end-user token"
        )

      {:error, :invalid_title} ->
        ErrorResponse.unprocessable_entity(
          conn,
          "v1.invalid_title",
          "title must be a non-empty string"
        )

      # ensure_group/1 — a direct chat has no title to set.
      {:error, :conversation_invalid} ->
        ErrorResponse.unprocessable_entity(
          conn,
          "v1.invalid_conversation",
          "Only a group conversation can be renamed"
        )

      {:error, :conversation_forbidden} ->
        ErrorResponse.forbidden(
          conn,
          "v1.not_owner",
          "Only the group owner can rename this conversation"
        )

      {:error, :conversation_unavailable} ->
        ErrorResponse.service_unavailable(conn, "v1.unavailable")

      _ ->
        ErrorResponse.not_found(conn, "v1.not_found", "Not found")
    end
  end

  defp require_end_user(conn) do
    case conn.assigns[:v1_user_id] do
      user_id when is_binary(user_id) and user_id != "" -> {:ok, user_id}
      _ -> {:error, :end_user_only}
    end
  end

  defp fetch_title(params) do
    case Map.get(params, "title") do
      title when is_binary(title) and title != "" -> {:ok, title}
      _ -> {:error, :invalid_title}
    end
  end

  def create(conn, params) do
    app_id = conn.assigns.v1_app_id

    with {:ok, type} <- fetch_type(params),
         {:ok, externals} <- fetch_participants(params),
         {:ok, user_ids} <- resolve_participants(app_id, externals),
         {:ok, created_by, participant_user_ids} <- creator_and_participants(conn, user_ids),
         {:ok, conversation} <-
           SharedInfra.ConversationClient.create_conversation(%{
             "app_id" => app_id,
             "type" => type,
             "title" => Map.get(params, "title"),
             "created_by" => created_by,
             "participant_user_ids" => participant_user_ids
           }) do
      # Live-update each non-creator participant's inbox — only on a genuine insert (an idempotent direct
      # returning an existing thread carries created:false → no broadcast). Fire-and-forget.
      ApiGatewayWeb.ConversationBroadcast.broadcast_created(conversation)

      conn
      |> put_status(:created)
      |> json(ApiGatewayWeb.ConversationBroadcast.strip_internal(conversation))
    else
      {:error, :conversation_unavailable} ->
        ErrorResponse.service_unavailable(conn, "v1.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "v1.invalid_request")
    end
  end

  # Who creates the conversation, and the final participant set.
  #   * end-user actor → created_by is the CALLER (v1_user_id), and the caller is guaranteed a participant
  #     (added if the request omitted them) — never create a conversation the caller isn't in.
  #   * app actor (no user_id) → unchanged: the first resolved participant is the creator (a server has no
  #     caller-user).
  defp creator_and_participants(conn, user_ids) do
    case conn.assigns[:v1_user_id] do
      user_id when is_binary(user_id) and user_id != "" ->
        {:ok, user_id, Enum.uniq([user_id | user_ids])}

      _ ->
        case List.first(user_ids) do
          nil -> {:error, :invalid_request}
          first -> {:ok, first, user_ids}
        end
    end
  end

  # Present a membership list row as a SAFE /v1 shape: conversation-level metadata only. The internal
  # group-avatar storage keys are dropped (presigning is deferred); the rows carry no participant user_ids.
  defp present_list(conversations, limit) do
    conversations
    |> Enum.take(limit)
    |> Enum.map(fn c ->
      %{
        conversation_id: cget(c, :conversation_id),
        type: cget(c, :type),
        title: cget(c, :title),
        last_message_preview: cget(c, :last_message_preview),
        last_message_kind: cget(c, :last_message_kind),
        unread_count: cget(c, :unread_count),
        updated_at: cget(c, :updated_at)
      }
    end)
  end

  defp cget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp cget(_map, _key), do: nil

  defp list_limit(params) do
    case Integer.parse(to_string(params["limit"] || "")) do
      {n, _} -> n |> max(1) |> min(100)
      :error -> 30
    end
  end

  defp fetch_type(params) do
    case Map.get(params, "type") do
      type when type in ["direct", "group"] -> {:ok, type}
      _ -> {:error, :invalid_request}
    end
  end

  defp fetch_participants(params) do
    case Map.get(params, "participants") do
      list when is_list(list) and list != [] ->
        if Enum.all?(list, &(is_binary(&1) and &1 != "")),
          do: {:ok, list},
          else: {:error, :invalid_request}

      _ ->
        {:error, :invalid_request}
    end
  end

  defp resolve_participants(app_id, externals) do
    externals
    |> Enum.reduce_while({:ok, []}, fn external_id, {:ok, acc} ->
      case SharedInfra.AuthClient.resolve_external_user(%{
             "app_id" => app_id,
             "external_id" => external_id
           }) do
        {:ok, %{user_id: user_id}} -> {:cont, {:ok, acc ++ [user_id]}}
        _ -> {:halt, {:error, :invalid_request}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.uniq(ids)}
      other -> other
    end
  end
end
