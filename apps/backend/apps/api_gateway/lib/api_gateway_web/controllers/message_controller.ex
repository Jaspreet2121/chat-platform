defmodule ApiGatewayWeb.MessageController do
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  def create(conn, %{"conversation_id" => conversation_id} = params) do
    if message_persistence_enabled?() do
      create_message_from_store(conn, conversation_id, params)
    else
      placeholder_create_message(conn, conversation_id, params)
    end
  end

  defp placeholder_create_message(conn, conversation_id, params) do
    params = Map.put(params, "conversation_id", conversation_id)

    with :ok <- validate_send_payload(params),
         {:ok, response} <- SharedInfra.MessageClient.send_message(params) do
      conn
      |> put_status(:created)
      |> json(response)
    else
      _ -> invalid_request(conn)
    end
  end

  defp create_message_from_store(conn, conversation_id, params) do
    params = Map.put(params, "conversation_id", conversation_id)

    with :ok <- validate_send_payload(params),
         {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         :ok <- authorize_membership(conversation_id, session.user_id),
         # SERVER-SIDE only-admins-can-send enforcement (a member can't bypass via the API). This SAME call
         # also carries the BLOCK disposition: for a DIRECT chat the recipient has blocked, delivery: "drop".
         {:ok, disposition} <-
           SharedInfra.ConversationClient.authorize_send(%{
             "conversation_id" => conversation_id,
             "user_id" => session.user_id
           }),
         dropped? = dropped?(disposition),
         {:ok, response} <-
           params
           |> Map.put("sender_user_id", session.user_id)
           |> put_delivery(dropped?)
           |> SharedInfra.MessageClient.create_message() do
      # A DROPPED (blocked) message returns a canonical single-tick ack to the SENDER but reaches the blocker
      # through NO path: nothing persisted, and the inbox fan-out below (which would wake the blocker's list)
      # is skipped. The sender learns nothing.
      unless dropped? do
        # Live inbox: new preview + updated_at for all, +1 unread for everyone but the sender.
        ApiGatewayWeb.ConversationBroadcast.broadcast_updated(
          conversation_id,
          session.user_id,
          :message
        )
      end

      conn
      |> put_status(:created)
      |> json(response)
    else
      {:error, :session_invalid} ->
        unauthorized(conn)

      {:error, :auth_unavailable} ->
        service_unavailable(conn)

      {:error, :message_unavailable} ->
        service_unavailable(conn)

      {:error, :conversation_unavailable} ->
        service_unavailable(conn)

      {:error, :conversation_membership_forbidden} ->
        forbidden(conn)

      {:error, :only_admins_can_send} ->
        ErrorResponse.forbidden(
          conn,
          "group.only_admins_can_send",
          "Only admins can send messages"
        )

      # Malformed polls are rejected with SPECIFIC codes — never stored broken.
      {:error, poll_error}
      when poll_error in [
             :poll_invalid_question,
             :poll_too_few_options,
             :poll_too_many_options,
             :poll_invalid_option,
             :poll_duplicate_option
           ] ->
        poll_invalid(conn, poll_error)

      _ ->
        invalid_request(conn)
    end
  end

  # "poll_invalid_question" → "polls.invalid_question" etc. — the atom names the failure exactly.
  defp poll_invalid(conn, poll_error) do
    "poll_" <> failure = Atom.to_string(poll_error)
    ErrorResponse.invalid_request(conn, "polls." <> failure)
  end

  def index(conn, %{"conversation_id" => conversation_id} = params) do
    if message_persistence_enabled?() do
      list_messages_from_store(conn, conversation_id, params)
    else
      placeholder_list_messages(conn, conversation_id, params)
    end
  end

  defp placeholder_list_messages(conn, conversation_id, params) do
    params = Map.put(params, "conversation_id", conversation_id)

    with {:ok, response} <- SharedInfra.MessageClient.list_timeline(params) do
      json(conn, response)
    end
  end

  defp list_messages_from_store(conn, conversation_id, params) do
    params = Map.put(params, "conversation_id", conversation_id)

    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         :ok <- authorize_membership(conversation_id, session.user_id),
         {:ok, response} <-
           params
           |> Map.put("viewer_user_id", session.user_id)
           |> SharedInfra.MessageClient.list_messages() do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :conversation_membership_forbidden} -> forbidden(conn)
      _ -> invalid_request(conn)
    end
  end

  # Shared-media gallery: the conversation's media messages (newest first, cursor-paginated).
  # Membership-gated EXACTLY like the timeline; the viewer's clear-chat/auto-delete window applies
  # (viewer_user_id passed); presigned URLs are resolved client-side per item (same as chat bubbles).
  def media(conn, %{"conversation_id" => conversation_id} = params) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         :ok <- authorize_membership(conversation_id, session.user_id),
         {:ok, response} <-
           SharedInfra.MessageClient.list_media(%{
             "conversation_id" => conversation_id,
             "viewer_user_id" => session.user_id,
             "limit" => params["limit"],
             "before" => params["before"]
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :conversation_membership_forbidden} -> forbidden(conn)
      _ -> invalid_request(conn)
    end
  end

  # Set/change the caller's reaction on a message (WhatsApp one-per-user). Members only.
  def react(conn, %{"conversation_id" => conversation_id, "message_id" => message_id} = params) do
    with {:ok, emoji} <- require_emoji(params),
         {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         :ok <- authorize_membership(conversation_id, session.user_id),
         {:ok, response} <-
           SharedInfra.MessageClient.add_reaction(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id,
             "user_id" => session.user_id,
             "emoji" => emoji
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :conversation_membership_forbidden} -> forbidden(conn)
      _ -> invalid_request(conn)
    end
  end

  # Remove the caller's reaction from a message.
  def unreact(conn, %{"conversation_id" => conversation_id, "message_id" => message_id}) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         :ok <- authorize_membership(conversation_id, session.user_id),
         {:ok, response} <-
           SharedInfra.MessageClient.remove_reaction(%{
             "message_id" => message_id,
             "user_id" => session.user_id
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :conversation_membership_forbidden} -> forbidden(conn)
      _ -> invalid_request(conn)
    end
  end

  defp require_emoji(params) do
    case Map.get(params, "emoji") do
      emoji when is_binary(emoji) and emoji != "" -> {:ok, emoji}
      _ -> {:error, :invalid_request}
    end
  end

  # Star (bookmark) a message for the caller — private, no broadcast. Members only.
  def star(conn, %{"conversation_id" => conversation_id, "message_id" => message_id}) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         :ok <- authorize_membership(conversation_id, session.user_id),
         {:ok, response} <-
           SharedInfra.MessageClient.star_message(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id,
             "user_id" => session.user_id
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :conversation_membership_forbidden} -> forbidden(conn)
      _ -> invalid_request(conn)
    end
  end

  # Unstar a message for the caller.
  def unstar(conn, %{"conversation_id" => conversation_id, "message_id" => message_id}) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         :ok <- authorize_membership(conversation_id, session.user_id),
         {:ok, response} <-
           SharedInfra.MessageClient.unstar_message(%{
             "message_id" => message_id,
             "user_id" => session.user_id
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :conversation_membership_forbidden} -> forbidden(conn)
      _ -> invalid_request(conn)
    end
  end

  @doc """
  Vote on a poll — the submitted option_ids set REPLACES the caller's whole vote set (first vote /
  change / un-vote([]) / multi-toggle are all this one idempotent verb). Membership-gated like sends —
  late joiners can vote; leavers can't (their prior votes remain counted). Returns the fresh aggregate
  AND broadcasts `poll_updated` {conversation_id, message_id, poll} to the conversation topic — the
  same transport reaction_updated uses (the socket is mounted on THIS endpoint). The broadcast is an
  optimization: history fetches recompute the aggregate from poll_votes, so a client that misses the
  event converges on refetch.
  """
  def vote(conn, %{"conversation_id" => conversation_id, "message_id" => message_id} = params) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         :ok <- authorize_membership(conversation_id, session.user_id),
         {:ok, response} <-
           SharedInfra.MessageClient.vote_poll(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id,
             "user_id" => session.user_id,
             "option_ids" => params["option_ids"]
           }) do
      poll = cget(response, :poll)

      # Live results for everyone with the conversation open. Viewer-INDEPENDENT payload (voter_ids are
      # public), so broadcasting the whole aggregate is safe — clients apply it wholesale.
      ApiGatewayWeb.Endpoint.broadcast("conversation:" <> conversation_id, "poll_updated", %{
        conversation_id: conversation_id,
        message_id: message_id,
        poll: poll
      })

      json(conn, %{message_id: message_id, poll: poll})
    else
      {:error, :session_invalid} ->
        unauthorized(conn)

      {:error, :auth_unavailable} ->
        service_unavailable(conn)

      {:error, :message_unavailable} ->
        service_unavailable(conn)

      {:error, :conversation_unavailable} ->
        service_unavailable(conn)

      {:error, :conversation_membership_forbidden} ->
        forbidden(conn)

      {:error, :message_not_found} ->
        not_found(conn)

      {:error, :poll_invalid_option} ->
        ErrorResponse.invalid_request(conn, "polls.invalid_option")

      {:error, :poll_single_choice} ->
        ErrorResponse.invalid_request(conn, "polls.single_choice")

      _ ->
        invalid_request(conn)
    end
  end

  @doc """
  The UNCAPPED per-option voter lists (the "view votes" screen — the aggregate's voter_ids are capped
  at 20 per option; MessageService.Polls.voter_ids_cap/0 is the source of truth). Membership-gated;
  voters are public to participants (explicitly NOT read receipts — no privacy setting composes with
  poll votes).
  """
  def poll_votes(conn, %{"conversation_id" => conversation_id, "message_id" => message_id}) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         :ok <- authorize_membership(conversation_id, session.user_id),
         {:ok, response} <-
           SharedInfra.MessageClient.list_poll_votes(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id
           }) do
      json(conn, %{message_id: message_id, poll: cget(response, :poll)})
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      {:error, :conversation_membership_forbidden} -> forbidden(conn)
      {:error, :message_not_found} -> not_found(conn)
      _ -> invalid_request(conn)
    end
  end

  @doc """
  Message info — WhatsApp's Info screen: WHO has received / read this message, per user, SENDER-only.

  Gates: session → membership (non-member / unknown conversation → 404, existence-hiding) → the store
  re-verifies the message (unknown / wrong conversation / TOMBSTONED → 404) and the sender
  (non-sender member → 403 messages.not_sender — they already know the message exists).

  Privacy IS the read_by_count rule (the shared read_receipts_on predicate + viewer_sees_read_receipts?):
  a receipts-off reader appears under delivered, never read; `read_hidden: true` means the SENDER'S OWN
  setting hides read state ("You have read receipts turned off") — NOT that nobody read it. DEPARTED
  members' receipts are kept (history, not membership); their names still resolve (profiles aren't
  membership-scoped), though contacts-gated photos may redact to nil. Entries are enriched through
  ProfilePresenter (block + photo redaction, exactly as everywhere else); an unresolvable profile
  degrades to {user_id, display_name: nil, avatar_url: nil} — present but nameless, never a crash.
  """
  def info(conn, %{"conversation_id" => conversation_id, "message_id" => message_id}) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         :ok <- authorize_membership(conversation_id, session.user_id),
         {:ok, info} <-
           SharedInfra.MessageClient.message_info(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id,
             "viewer_user_id" => session.user_id
           }) do
      json(conn, %{
        conversation_id: conversation_id,
        message_id: message_id,
        read: enrich_info_entries(cget(info, :read), session, :read_at),
        delivered: enrich_info_entries(cget(info, :delivered), session, :delivered_at),
        read_hidden: cget(info, :read_hidden) == true
      })
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      {:error, :conversation_unavailable} -> service_unavailable(conn)
      # Membership failure → 404 here (not the usual 403): info must not reveal message existence to
      # outsiders, matching the "unknown message → 404" posture.
      {:error, :conversation_membership_forbidden} -> not_found(conn)
      {:error, :message_not_found} -> not_found(conn)
      {:error, :not_sender} -> not_sender(conn)
      _ -> invalid_request(conn)
    end
  end

  # Enrich each {user_id, timestamp} receipt entry with display_name + avatar_url through the SAME
  # ProfilePresenter path as every other profile surface (block + photo-visibility redaction). O(entries)
  # PK lookups by design — the deliberate cost of per-viewer redaction (bulk-restating it is the drift
  # the privacy slice forbids). A departed/deleted profile degrades to a nameless entry, never a crash.
  defp enrich_info_entries(entries, session, timestamp_key) when is_list(entries) do
    Enum.map(entries, fn entry ->
      user_id = cget(entry, :user_id)

      base =
        %{user_id: user_id, display_name: nil, avatar_url: nil}
        |> Map.put(timestamp_key, cget(entry, timestamp_key))

      with {:ok, profile} <-
             SharedInfra.UserClient.get_public_profile(%{
               "user_id" => user_id,
               "app_id" => Map.get(session, :app_id)
             }),
           presented when is_map(presented) <-
             ApiGatewayWeb.ProfilePresenter.present(session.user_id, user_id, profile) do
        %{
          base
          | display_name: cget(presented, :display_name),
            avatar_url: cget(presented, :avatar_url)
        }
      else
        _ -> base
      end
    end)
  rescue
    _ ->
      Enum.map(entries, fn entry ->
        %{user_id: cget(entry, :user_id), display_name: nil, avatar_url: nil}
        |> Map.put(timestamp_key, cget(entry, timestamp_key))
      end)
  end

  defp enrich_info_entries(_entries, _session, _timestamp_key), do: []

  defp not_sender(conn),
    do:
      ErrorResponse.forbidden(
        conn,
        "messages.not_sender",
        "Only the sender can see this message's info"
      )

  # Presence-based (SharedInfra.Attrs): reads :read_hidden (a boolean) — `||` drops a stored false.
  defp cget(map, key) when is_map(map), do: SharedInfra.Attrs.get(map, key)
  defp cget(_map, _key), do: nil

  def update(conn, %{"conversation_id" => conversation_id, "message_id" => message_id} = params) do
    if message_persistence_enabled?() do
      update_message_in_store(conn, conversation_id, message_id, params)
    else
      placeholder_update_message(conn, conversation_id, message_id, params)
    end
  end

  defp placeholder_update_message(conn, conversation_id, message_id, params) do
    params =
      params
      |> Map.put("conversation_id", conversation_id)
      |> Map.put("message_id", message_id)

    with :ok <- require_fields(params, ["body"]),
         {:ok, response} <- SharedInfra.MessageClient.edit_message(params) do
      json(conn, response)
    else
      _ -> invalid_request(conn)
    end
  end

  defp update_message_in_store(conn, conversation_id, message_id, params) do
    params =
      params
      |> Map.put("conversation_id", conversation_id)
      |> Map.put("message_id", message_id)

    with :ok <- require_fields(params, ["body"]),
         {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           params
           |> Map.put("actor_user_id", session.user_id)
           |> SharedInfra.MessageClient.update_message() do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      {:error, :message_forbidden} -> forbidden(conn)
      # A soft-deleted message is GONE — an edit would resurrect the tombstone. 404, not 403: it isn't a
      # permission problem (you DO own it), the message simply no longer exists to edit.
      {:error, :message_deleted} -> not_found(conn)
      _ -> invalid_request(conn)
    end
  end

  def delete(conn, %{"conversation_id" => conversation_id, "message_id" => message_id}) do
    if message_persistence_enabled?() do
      delete_message_from_store(conn, conversation_id, message_id)
    else
      placeholder_delete_message(conn, conversation_id, message_id)
    end
  end

  defp placeholder_delete_message(conn, conversation_id, message_id) do
    with {:ok, response} <-
           SharedInfra.MessageClient.delete_message(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id
           }) do
      json(conn, response)
    end
  end

  defp delete_message_from_store(conn, conversation_id, message_id) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           SharedInfra.MessageClient.delete_message(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id,
             "actor_user_id" => session.user_id
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      {:error, :message_forbidden} -> forbidden(conn)
      _ -> invalid_request(conn)
    end
  end

  def read(conn, %{"conversation_id" => conversation_id, "message_id" => message_id}) do
    if message_persistence_enabled?() do
      mark_read_in_store(conn, conversation_id, message_id)
    else
      placeholder_mark_read(conn, conversation_id, message_id)
    end
  end

  defp placeholder_mark_read(conn, conversation_id, message_id) do
    with {:ok, response} <-
           SharedInfra.MessageClient.mark_read(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id
           }) do
      json(conn, response)
    end
  end

  defp mark_read_in_store(conn, conversation_id, message_id) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         # BEFORE the write: re-reading an already-read message leaves unread unchanged, and an identical
         # inbox row must not be re-broadcast on every such call.
         unread_before <-
           ApiGatewayWeb.ConversationBroadcast.unread_before(conversation_id, session.user_id),
         {:ok, response} <-
           SharedInfra.MessageClient.mark_read(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id,
             "user_id" => session.user_id
           }) do
      # Only the READER's badge changed → fan out to them alone, and only if it actually moved.
      ApiGatewayWeb.ConversationBroadcast.broadcast_updated(
        conversation_id,
        session.user_id,
        :receipt,
        only: [session.user_id],
        skip_if_unread: unread_before
      )

      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      _ -> invalid_request(conn)
    end
  end

  def delivered(conn, %{"conversation_id" => conversation_id, "message_id" => message_id}) do
    if message_persistence_enabled?() do
      mark_delivered_in_store(conn, conversation_id, message_id)
    else
      placeholder_mark_delivered(conn, conversation_id, message_id)
    end
  end

  defp placeholder_mark_delivered(conn, conversation_id, message_id) do
    with {:ok, response} <-
           SharedInfra.MessageClient.mark_delivered(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id
           }) do
      json(conn, response)
    end
  end

  defp mark_delivered_in_store(conn, conversation_id, message_id) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <-
           SharedInfra.MessageClient.mark_delivered(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id,
             "user_id" => session.user_id
           }) do
      json(conn, response)
    else
      {:error, :session_invalid} -> unauthorized(conn)
      {:error, :auth_unavailable} -> service_unavailable(conn)
      {:error, :message_unavailable} -> service_unavailable(conn)
      _ -> invalid_request(conn)
    end
  end

  defp validate_send_payload(%{"message_type" => "text"} = params) do
    require_fields(params, ["body"])
  end

  defp validate_send_payload(params), do: require_fields(params, ["message_type"])

  defp require_fields(params, fields) do
    if Enum.all?(fields, &present?(params[&1])) do
      :ok
    else
      {:error, :invalid_request}
    end
  end

  defp present?(value), do: not is_nil(value) and value != ""

  # The send gate's disposition: delivery: "drop" means the recipient blocked the sender (DIRECT chat).
  defp dropped?(disposition) when is_map(disposition),
    do: Map.get(disposition, :delivery) == "drop" or Map.get(disposition, "delivery") == "drop"

  defp dropped?(_disposition), do: false

  # SERVER-controlled flag: set on a drop, STRIP any client-injected value otherwise (a client must never be
  # able to force the synthesize path).
  defp put_delivery(params, true), do: Map.put(params, "delivery_disposition", "drop")
  defp put_delivery(params, false), do: Map.delete(params, "delivery_disposition")

  defp invalid_request(conn), do: ErrorResponse.invalid_request(conn, "message.invalid_request")

  defp not_found(conn),
    do: ErrorResponse.not_found(conn, "message.not_found", "Message not found")

  defp service_unavailable(conn),
    do: ErrorResponse.service_unavailable(conn, "message.unavailable")

  defp unauthorized(conn),
    do:
      ErrorResponse.unauthorized(conn, "message.unauthorized", "Missing or invalid access token")

  defp forbidden(conn),
    do:
      ErrorResponse.forbidden(conn, "message.forbidden", "You can only modify your own messages")

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> _token = authorization] -> {:ok, authorization}
      _ -> {:error, :session_invalid}
    end
  end

  # Membership gate for HTTP message create/list, reusing the same Conversation
  # Service check the realtime channel-join path uses. When conversation
  # persistence is OFF, get_conversation returns a placeholder {:ok} so the
  # placeholder/Docker-free path is unchanged (enforcement is only meaningful
  # when conversation persistence is enabled).
  defp authorize_membership(conversation_id, user_id) do
    case SharedInfra.ConversationClient.get_conversation(%{
           "conversation_id" => conversation_id,
           "user_id" => user_id
         }) do
      {:ok, _conversation} -> :ok
      # Propagate transport-unavailable so the controller maps it to 503 (not a 403 forbidden).
      {:error, :conversation_unavailable} -> {:error, :conversation_unavailable}
      _ -> {:error, :conversation_membership_forbidden}
    end
  end

  defp message_persistence_enabled? do
    Application.get_env(:message_service, :message_persistence, false) ||
      System.get_env("MESSAGE_DB_BACKED") in ["true", "1", "yes"]
  end
end
