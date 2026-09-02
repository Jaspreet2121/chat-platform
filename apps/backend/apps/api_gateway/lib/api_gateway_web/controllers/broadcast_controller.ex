defmodule ApiGatewayWeb.BroadcastController do
  @moduledoc """
  Broadcast lists — send one message to many contacts as SEPARATE private DMs. A list is a saved
  recipient set, NOT a conversation; recipients receive an ordinary 1-on-1 message and can never learn
  a broadcast exists (no broadcast id on the wire — the SEND RESPONSE carries every (conversation_id,
  message_id) pair so the SENDER'S client tags its own copies locally).

    POST   /api/v1/broadcasts             {name, member_user_ids}      → the list
    GET    /api/v1/broadcasts                                          → {lists: [...]}
    PATCH  /api/v1/broadcasts/:list_id    {name?, member_user_ids?}    → the list (members = full replace)
    DELETE /api/v1/broadcasts/:list_id                                 → {deleted: true}
    POST   /api/v1/broadcasts/:list_id/send {message_type, body, ...}  → the per-recipient results

  SEND runs the EXACT per-message REST sequence per recipient — resolve-or-create the direct
  conversation (the same find_or_create_direct entry point a normal first message uses), authorize_send
  (the BLOCK disposition → synthetic drop, so a blocking recipient's result is BYTE-indistinguishable
  from a delivered one), create_message, and the same live broadcasts. Partial success: one recipient's
  failure never aborts the rest.

  NOT IDEMPOTENT — documented hazard: the fan-out is synchronous (2–8s at the 256 cap), and if the
  CONNECTION dies mid-loop the already-served recipients keep their (real, independent) messages while
  the caller gets no response; RETRYING THE SAME SEND WILL DOUBLE-SEND to them. There is no cheap
  idempotency key without new storage (message ids are server-generated), so instead: every recipient
  outcome is logged under a per-send op id (reconstructable server-side), and the client-side recovery
  is to refetch its OWN DMs — the sent messages are visible in the sender's conversations, so a client
  can diff which members already received it before retrying.

  Concurrency bound: DB connections are checked out PER QUERY (the loop wraps no transaction), so
  concurrent broadcasts degrade to queueing, not pool exhaustion; the pathological case — ONE user
  firing parallel sends — is closed by a per-user SINGLE-FLIGHT lock (409 broadcasts.send_in_progress),
  and the 20/hour fail-CLOSED limiter (spam amplifier ⇒ security control: ceiling 20 × 256 = 5,120
  messages/hour/account) bounds the rest.
  """
  use ApiGatewayWeb, :controller

  require Logger

  alias ApiGatewayWeb.ErrorResponse

  @member_limit 256
  @list_limit 32
  @send_rate_limit 20
  @send_rate_window_seconds 3600
  @limiter_retry_after "30"
  # A crashed fan-out's lock goes stale after this many seconds (the table outlives the request).
  @lock_stale_seconds 120
  @lock_table :broadcast_send_locks

  # Only these ride through to create_message — the server owns everything else (sender, conversation,
  # delivery disposition).
  @message_fields [
    "message_type",
    "body",
    "media_id",
    "caption",
    "metadata",
    "reply_to_message_id"
  ]

  # --- CRUD --------------------------------------------------------------------------------------

  def create(conn, params) do
    with {:ok, session} <- session(conn),
         {:ok, result} <-
           SharedInfra.ConversationClient.create_broadcast_list(%{
             "owner_user_id" => session.user_id,
             "app_id" => session_app(session),
             "name" => params["name"],
             "member_user_ids" => params["member_user_ids"]
           }) do
      conn |> put_status(:created) |> json(result)
    else
      error -> handle_error(conn, error)
    end
  end

  def index(conn, _params) do
    with {:ok, session} <- session(conn),
         {:ok, result} <-
           SharedInfra.ConversationClient.list_broadcast_lists(%{
             "owner_user_id" => session.user_id
           }) do
      json(conn, result)
    else
      error -> handle_error(conn, error)
    end
  end

  def update(conn, %{"list_id" => list_id} = params) do
    with {:ok, session} <- session(conn),
         {:ok, result} <-
           SharedInfra.ConversationClient.update_broadcast_list(%{
             "owner_user_id" => session.user_id,
             "list_id" => list_id,
             "name" => params["name"],
             "member_user_ids" => params["member_user_ids"]
           }) do
      json(conn, result)
    else
      error -> handle_error(conn, error)
    end
  end

  def delete(conn, %{"list_id" => list_id}) do
    with {:ok, session} <- session(conn),
         {:ok, result} <-
           SharedInfra.ConversationClient.delete_broadcast_list(%{
             "owner_user_id" => session.user_id,
             "list_id" => list_id
           }) do
      json(conn, result)
    else
      error -> handle_error(conn, error)
    end
  end

  # --- SEND --------------------------------------------------------------------------------------

  def send_broadcast(conn, %{"list_id" => list_id} = params) do
    with {:ok, session} <- session(conn),
         :ok <- validate_message(params),
         :ok <- send_rate_limit(session.user_id),
         {:ok, list} <-
           SharedInfra.ConversationClient.get_broadcast_list(%{
             "owner_user_id" => session.user_id,
             "list_id" => list_id
           }),
         :ok <- acquire_send_lock(session.user_id) do
      try do
        recipients = cget(list, :sendable_member_ids) || []
        op_id = SharedInfra.Correlation.get_or_generate()
        message_params = Map.take(params, @message_fields)

        Logger.info(
          "broadcast_send start op=#{op_id} user=#{session.user_id} list=#{list_id} recipients=#{length(recipients)}"
        )

        results = Enum.map(recipients, &send_to_recipient(session, &1, message_params, op_id))
        sent = Enum.count(results, &(&1.status == "sent"))

        Logger.info("broadcast_send done op=#{op_id} sent=#{sent}/#{length(results)}")

        json(conn, %{
          list_id: list_id,
          sent_count: sent,
          failed_count: length(results) - sent,
          results: results
        })
      after
        release_send_lock(session.user_id)
      end
    else
      error -> handle_error(conn, error)
    end
  end

  # ONE recipient = the exact REST create sequence: resolve-or-create the DM (same entry point as a
  # normal first message → identical conversation, race-safe), block disposition, create (synthetic ack
  # on drop — the entry below is then INDISTINGUISHABLE from a delivered one), live broadcasts (skipped
  # on drop, exactly like the single-send path). Any failure yields {status: "failed"} and the loop
  # continues — recipients are independent.
  defp send_to_recipient(session, recipient, message_params, op_id) do
    with {:ok, conversation} <-
           SharedInfra.ConversationClient.create_conversation(%{
             "type" => "direct",
             "participant_user_ids" => [recipient],
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
           message_params
           |> Map.put("conversation_id", conversation_id)
           |> Map.put("sender_user_id", session.user_id)
           |> put_delivery(dropped?)
           |> SharedInfra.MessageClient.create_message() do
      # A genuinely fresh DM tells the recipient's inbox it exists (no-op for :existing rows).
      ApiGatewayWeb.ConversationBroadcast.broadcast_created(conversation)

      unless dropped? do
        ApiGatewayWeb.ConversationBroadcast.broadcast_updated(
          conversation_id,
          session.user_id,
          :message
        )
      end

      message_id = cget(message, :message_id)

      # The reconstruction trail for a connection that dies mid-loop (the op is NOT idempotent).
      Logger.info(
        "broadcast_send op=#{op_id} recipient=#{recipient} conversation=#{conversation_id} message=#{message_id} ok"
      )

      %{
        user_id: recipient,
        status: "sent",
        conversation_id: conversation_id,
        message_id: message_id
      }
    else
      _ ->
        Logger.warning("broadcast_send op=#{op_id} recipient=#{recipient} failed")
        %{user_id: recipient, status: "failed"}
    end
  end

  defp validate_message(params) do
    cond do
      # VIEW-ONCE IS REFUSED, LOUDLY, rather than dropped by the @message_fields take below. One
      # media_id fans out to N conversations here, each needing its own per-recipient open — but the
      # FIRST open deletes the blob for everyone, so recipients 2..N would silently lose a message
      # they were told they had. Silently stripping the flag would be worse: the sender would believe
      # they sent view-once and be wrong.
      truthy_view_once?(params["view_once"]) ->
        {:error, :view_once_unsupported}

      is_binary(params["message_type"]) and params["message_type"] != "" ->
        :ok

      true ->
        {:error, :message_invalid}
    end
  end

  defp truthy_view_once?(true), do: true
  defp truthy_view_once?("true"), do: true
  defp truthy_view_once?(_), do: false

  # Spam-amplifier control (contacts-sync idiom): FAIL-CLOSED — a limiter outage rejects rather than
  # opening a 5,120-messages/hour gate.
  defp send_rate_limit(user_id) do
    case SharedInfra.RateLimiter.check_rate(%{
           "key" => "broadcast_send:" <> user_id,
           "limit" => @send_rate_limit,
           "window_seconds" => @send_rate_window_seconds,
           "fail_open" => false
         }) do
      :ok -> :ok
      {:error, :rate_limited, _retry} = limited -> limited
      _ -> {:error, :rate_limiter_unavailable}
    end
  end

  # Per-user single-flight (the table is owned by V1Runtime, so it outlives a crashed request; a stale
  # entry — older than @lock_stale_seconds — is treated as free).
  defp acquire_send_lock(user_id) do
    now = System.system_time(:second)

    if :ets.insert_new(@lock_table, {user_id, now}) do
      :ok
    else
      case :ets.lookup(@lock_table, user_id) do
        [{^user_id, at}] when now - at > @lock_stale_seconds ->
          :ets.insert(@lock_table, {user_id, now})
          :ok

        _ ->
          {:error, :send_in_progress}
      end
    end
  end

  defp release_send_lock(user_id), do: :ets.delete(@lock_table, user_id)

  # --- plumbing ----------------------------------------------------------------------------------

  defp dropped?(disposition) when is_map(disposition),
    do: SharedInfra.Attrs.get(disposition, :delivery) == "drop"

  defp dropped?(_disposition), do: false

  defp put_delivery(params, true), do: Map.put(params, "delivery_disposition", "drop")
  defp put_delivery(params, false), do: Map.delete(params, "delivery_disposition")

  defp session(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" ->
        SharedInfra.AuthClient.current_session(%{"authorization" => "Bearer " <> token})

      _ ->
        {:error, :session_invalid}
    end
  end

  defp session_app(session), do: Map.get(session, :app_id)

  defp handle_error(conn, {:error, :session_invalid}),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Invalid or missing session")

  defp handle_error(conn, {:error, :list_not_found}),
    do: ErrorResponse.not_found(conn, "broadcasts.not_found", "Broadcast list not found")

  defp handle_error(conn, {:error, :view_once_unsupported}),
    do:
      ErrorResponse.unprocessable_entity(
        conn,
        "broadcast.view_once_unsupported",
        "View-once messages cannot be broadcast"
      )

  defp handle_error(conn, {:error, :invalid_name}),
    do: ErrorResponse.invalid_request(conn, "broadcasts.invalid_name")

  defp handle_error(conn, {:error, :invalid_member}),
    do: ErrorResponse.invalid_request(conn, "broadcasts.invalid_member")

  defp handle_error(conn, {:error, :member_limit}),
    do:
      ErrorResponse.invalid_request_with(conn, "broadcasts.member_limit", "Too many members", %{
        limit: @member_limit
      })

  defp handle_error(conn, {:error, :list_limit}),
    do:
      ErrorResponse.invalid_request_with(
        conn,
        "broadcasts.list_limit",
        "Too many broadcast lists",
        %{
          limit: @list_limit
        }
      )

  defp handle_error(conn, {:error, :message_invalid}),
    do: ErrorResponse.invalid_request(conn, "broadcasts.message_invalid")

  defp handle_error(conn, {:error, :send_in_progress}),
    do:
      conn
      |> put_status(:conflict)
      |> json(%{
        error: %{
          code: "broadcasts.send_in_progress",
          message: "A broadcast from this account is already sending",
          correlation_id: SharedInfra.Correlation.get_or_generate()
        }
      })

  defp handle_error(conn, {:error, :rate_limited, retry_after_seconds}),
    do:
      conn
      |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
      |> ErrorResponse.rate_limited("broadcasts.rate_limited")

  defp handle_error(conn, {:error, :rate_limiter_unavailable}),
    do:
      conn
      |> put_resp_header("retry-after", @limiter_retry_after)
      |> ErrorResponse.service_unavailable("broadcasts.limiter_unavailable")

  defp handle_error(conn, {:error, :conversation_unavailable}),
    do: ErrorResponse.service_unavailable(conn, "broadcasts.unavailable")

  defp handle_error(conn, {:error, :auth_unavailable}),
    do: ErrorResponse.service_unavailable(conn, "broadcasts.unavailable")

  defp handle_error(conn, _other),
    do: ErrorResponse.invalid_request(conn, "broadcasts.invalid_request")

  defp cget(map, key) when is_map(map), do: SharedInfra.Attrs.get(map, key)
  defp cget(_map, _key), do: nil
end
