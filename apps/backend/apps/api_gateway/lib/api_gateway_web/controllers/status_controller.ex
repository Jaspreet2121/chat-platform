defmodule ApiGatewayWeb.StatusController do
  @moduledoc """
  STATUS (Stories), commit 1 — session-authed, first-party.

    POST   /api/v1/status                {kind, body?, media_id?, metadata?} → 201 the post
    GET    /api/v1/status/feed                                              → {my_status, threads}
    GET    /api/v1/status/:owner_user_id                                    → {posts} (audience-gated)
    DELETE /api/v1/status/:status_id                                        → {deleted: true}

  The FEED is one composite query (owners sharing a PREDATING active conversation with the viewer, live
  posts, blocks both ways) plus `my_status` — the viewer's own thread summary (WhatsApp's "My status"
  entry; view COUNTS arrive with viewer lists in commit 2). An owner the viewer can't see is simply
  ABSENT / an empty list — never an existence reveal. Media presigns are LAZY (fetched per-open via the
  media download route, whose purpose-"status" authz arm re-runs the SAME audience predicate) and
  SHORT-lived (300s).

  A posted image/video must reference the CALLER'S OWN ready "status"-purpose upload — the same
  ownership rule avatars enforce (a foreign or wrong-purpose media_id → 422 status.invalid_media).
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  def create(conn, params) do
    with {:ok, session} <- session(conn),
         :ok <- validate_media_ownership(params, session),
         {:ok, post} <-
           SharedInfra.MessageClient.post_status(%{
             "owner_user_id" => session.user_id,
             "app_id" => session_app(session),
             "kind" => params["kind"],
             "body" => params["body"],
             "media_id" => params["media_id"],
             "metadata" => params["metadata"]
           }) do
      conn |> put_status(:created) |> json(post)
    else
      error -> handle_error(conn, error)
    end
  end

  def feed(conn, _params) do
    with {:ok, session} <- session(conn),
         {:ok, %{threads: threads}} <-
           SharedInfra.MessageClient.status_feed(%{"viewer_user_id" => session.user_id}),
         # "My status" carries its VIEW COUNT (commit 2) under the same reciprocity as the viewer list:
         # 0 + viewers_hidden when the OWNER turned read receipts off.
         {:ok, my_status} <-
           SharedInfra.MessageClient.my_status(%{"owner_user_id" => session.user_id}) do
      json(conn, %{my_status: my_status, threads: threads})
    else
      error -> handle_error(conn, error)
    end
  end

  @doc """
  Audience settings — GET/PUT /api/v1/status/audience {mode, member_user_ids}. Per-USER (not per-post),
  WhatsApp's model. 'contacts' (default) | 'except' (contacts minus the list) | 'only' (contacts
  intersected with the list). Enforced inside the ONE shared audience predicate — modes narrow, never
  widen: an 'only' listee still needs the shared conversation to PREDATE the post.
  """
  def get_audience(conn, _params) do
    with {:ok, session} <- session(conn),
         {:ok, audience} <-
           SharedInfra.MessageClient.get_status_audience(%{"user_id" => session.user_id}) do
      json(conn, audience)
    else
      error -> handle_error(conn, error)
    end
  end

  def set_audience(conn, params) do
    with {:ok, session} <- session(conn),
         {:ok, audience} <-
           SharedInfra.MessageClient.set_status_audience(%{
             "user_id" => session.user_id,
             "mode" => params["mode"],
             "member_user_ids" => params["member_user_ids"]
           }) do
      json(conn, audience)
    else
      error -> handle_error(conn, error)
    end
  end

  @doc """
  Record that the caller opened a status. Gated by the SAME audience predicate — a viewer who can't see
  it can't record (404), so a BLOCKED viewer never produces a row. The row is the dedup key (first view
  wins); DISCLOSURE is filtered at read, so a receipts-off viewer still records one. The owner's own
  view records nothing.
  """
  def record_view(conn, %{"status_id" => status_id})
      when is_binary(status_id) and status_id != "" do
    with {:ok, session} <- session(conn),
         {:ok, result} <-
           SharedInfra.MessageClient.record_status_view(%{
             "status_id" => status_id,
             "viewer_user_id" => session.user_id
           }) do
      json(conn, result)
    else
      error -> handle_error(conn, error)
    end
  end

  def record_view(conn, _params),
    do: ErrorResponse.invalid_request(conn, "status.invalid_request")

  @doc """
  "Seen by" — the OWNER'S viewer list for one of their posts. Owner-only (anyone else → 404, no
  existence reveal). Reciprocity: a viewer appears iff THEY kept receipts on AND the owner did;
  `viewers_hidden: true` means the OWNER'S OWN setting hides it (client copy: "You have read receipts
  turned off"), never "nobody looked".
  """
  def viewers(conn, %{"status_id" => status_id}) when is_binary(status_id) and status_id != "" do
    with {:ok, session} <- session(conn),
         {:ok, result} <-
           SharedInfra.MessageClient.status_viewers(%{
             "status_id" => status_id,
             "owner_user_id" => session.user_id
           }) do
      json(conn, result)
    else
      error -> handle_error(conn, error)
    end
  end

  def viewers(conn, _params), do: ErrorResponse.invalid_request(conn, "status.invalid_request")

  def list(conn, %{"owner_user_id" => owner}) when is_binary(owner) and owner != "" do
    with {:ok, session} <- session(conn),
         {:ok, result} <-
           SharedInfra.MessageClient.list_status_posts(%{
             "viewer_user_id" => session.user_id,
             "owner_user_id" => owner
           }) do
      json(conn, result)
    else
      error -> handle_error(conn, error)
    end
  end

  def list(conn, _params), do: ErrorResponse.invalid_request(conn, "status.invalid_request")

  def delete(conn, %{"status_id" => status_id}) when is_binary(status_id) and status_id != "" do
    with {:ok, session} <- session(conn),
         {:ok, result} <-
           SharedInfra.MessageClient.delete_status(%{
             "owner_user_id" => session.user_id,
             "status_id" => status_id
           }) do
      json(conn, result)
    else
      error -> handle_error(conn, error)
    end
  end

  def delete(conn, _params), do: ErrorResponse.invalid_request(conn, "status.invalid_request")

  @doc """
  Reply to a status — an ORDINARY DM to its owner, quoting a TEXT-ONLY snapshot.

    POST /api/v1/status/:status_id/reply {body} → the created message

  The DM goes through the SAME create path as any other (resolve-or-create the direct conversation via
  find_or_create_direct, authorize_send's block disposition → synthetic drop, the usual live fan-out and
  push) — nothing about replies is special downstream. `metadata.status_ref` carries
  {status_id, kind, excerpt}: the excerpt is SNAPSHOTTED at reply time so the quote renders forever,
  and status_id is a courtesy pointer that simply goes dead at expiry (nothing dereferences it later).
  NO thumbnail — see MessageService.Statuses.status_for_reply/1 for why a pointer would decay and a
  copy would subvert the 24h ephemerality contract.

  THE AUDIENCE GATE RUNS AT REPLY TIME (audience is live): a caller who could view when they opened the
  status but has since been blocked / removed from an 'only' list / dropped from the conversation gets a
  clean 403 status.reply_forbidden — never a 500 or a silent drop. (That 403 confirms a live status
  exists to someone already holding its unguessable id; unknown/expired/deleted stay 404, so nothing is
  enumerable.) Replying to your OWN status is refused (409 status.cannot_reply_own): the participant set
  would dedupe to one, skipping find_or_create_direct entirely and minting a fresh orphan
  single-participant conversation on every reply.
  """
  def reply(conn, %{"status_id" => status_id} = params)
      when is_binary(status_id) and status_id != "" do
    with {:ok, session} <- session(conn),
         {:ok, body} <- reply_body(params),
         {:ok, status} <-
           SharedInfra.MessageClient.status_for_reply(%{
             "status_id" => status_id,
             "viewer_user_id" => session.user_id
           }),
         owner = cget(status, :owner_user_id),
         :ok <- refuse_self_reply(session.user_id, owner),
         {:ok, conversation} <-
           SharedInfra.ConversationClient.create_conversation(%{
             "type" => "direct",
             "participant_user_ids" => [owner],
             "created_by" => session.user_id,
             "app_id" => session_app(session)
           }),
         conversation_id = cget(conversation, :conversation_id),
         {:ok, disposition} <-
           SharedInfra.ConversationClient.authorize_send(%{
             "conversation_id" => conversation_id,
             "user_id" => session.user_id
           }),
         dropped? = dropped?(disposition),
         {:ok, message} <-
           %{
             "conversation_id" => conversation_id,
             "sender_user_id" => session.user_id,
             "message_type" => "text",
             "body" => body,
             "metadata" => %{
               "status_ref" => %{
                 "status_id" => status_id,
                 "kind" => cget(status, :kind),
                 "excerpt" => cget(status, :excerpt)
               }
             }
           }
           |> put_delivery(dropped?)
           |> SharedInfra.MessageClient.create_message() do
      ApiGatewayWeb.ConversationBroadcast.broadcast_created(conversation)

      unless dropped? do
        ApiGatewayWeb.ConversationBroadcast.broadcast_updated(
          conversation_id,
          session.user_id,
          :message
        )
      end

      conn |> put_status(:created) |> json(message)
    else
      error -> handle_error(conn, error)
    end
  end

  def reply(conn, _params), do: ErrorResponse.invalid_request(conn, "status.invalid_request")

  defp reply_body(%{"body" => body}) when is_binary(body) do
    if String.trim(body) != "", do: {:ok, body}, else: {:error, :status_invalid_body}
  end

  defp reply_body(_params), do: {:error, :status_invalid_body}

  defp refuse_self_reply(user_id, owner) when user_id == owner, do: {:error, :status_reply_own}
  defp refuse_self_reply(_user_id, _owner), do: :ok

  defp dropped?(disposition) when is_map(disposition),
    do: SharedInfra.Attrs.get(disposition, :delivery) == "drop"

  defp dropped?(_disposition), do: false

  defp put_delivery(params, true), do: Map.put(params, "delivery_disposition", "drop")
  defp put_delivery(params, false), do: Map.delete(params, "delivery_disposition")

  # A media status must reference the caller's OWN ready, "status"-purpose asset (the avatar ownership
  # rule): stops posting someone else's bytes or cross-purpose reuse. Text statuses skip this.
  defp validate_media_ownership(%{"media_id" => media_id}, session)
       when is_binary(media_id) and media_id != "" do
    case SharedInfra.MediaClient.get_asset(%{
           "media_id" => media_id,
           "app_id" => session_app(session)
         }) do
      {:ok, %{owner_user_id: owner, purpose: "status", status: "ready"}}
      when owner == session.user_id ->
        :ok

      {:error, :media_unavailable} ->
        {:error, :media_unavailable}

      _ ->
        {:error, :invalid_media}
    end
  end

  defp validate_media_ownership(_params, _session), do: :ok

  defp session(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" ->
        SharedInfra.AuthClient.current_session(%{"authorization" => "Bearer " <> token})

      _ ->
        {:error, :session_invalid}
    end
  end

  defp session_app(session), do: Map.get(session, :app_id)

  # Presence-based dual-key read (SharedInfra.Attrs): service results arrive atom-keyed in-process and
  # string-keyed over HTTP, and some fields are legitimately nil/false.
  defp cget(map, key) when is_map(map), do: SharedInfra.Attrs.get(map, key)
  defp cget(_map, _key), do: nil

  defp handle_error(conn, {:error, :session_invalid}),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Invalid or missing session")

  defp handle_error(conn, {:error, :status_invalid_kind}),
    do: ErrorResponse.invalid_request(conn, "status.invalid_kind")

  defp handle_error(conn, {:error, :status_invalid_body}),
    do: ErrorResponse.invalid_request(conn, "status.invalid_body")

  defp handle_error(conn, {:error, :status_media_required}),
    do: ErrorResponse.invalid_request(conn, "status.media_required")

  defp handle_error(conn, {:error, :invalid_media}),
    do:
      ErrorResponse.unprocessable_entity(
        conn,
        "status.invalid_media",
        "media_id must reference your own ready status upload"
      )

  defp handle_error(conn, {:error, :status_invalid_mode}),
    do: ErrorResponse.invalid_request(conn, "status.invalid_mode")

  defp handle_error(conn, {:error, :status_audience_limit}),
    do:
      ErrorResponse.invalid_request_with(
        conn,
        "status.audience_limit",
        "Too many audience members",
        %{limit: 256}
      )

  # Live status, caller outside the audience AT SEND TIME (live evaluation) — a specific, clean refusal.
  defp handle_error(conn, {:error, :status_not_visible}),
    do:
      ErrorResponse.forbidden(
        conn,
        "status.reply_forbidden",
        "This status is no longer available to you"
      )

  defp handle_error(conn, {:error, :status_reply_own}),
    do:
      ErrorResponse.conflict(
        conn,
        "status.cannot_reply_own",
        "You can't reply to your own status"
      )

  defp handle_error(conn, {:error, :status_not_found}),
    do: ErrorResponse.not_found(conn, "status.not_found", "Status not found")

  defp handle_error(conn, {:error, unavailable})
       when unavailable in [:message_unavailable, :auth_unavailable, :media_unavailable],
       do: ErrorResponse.service_unavailable(conn, "status.unavailable")

  defp handle_error(conn, _other),
    do: ErrorResponse.invalid_request(conn, "status.invalid_request")
end
