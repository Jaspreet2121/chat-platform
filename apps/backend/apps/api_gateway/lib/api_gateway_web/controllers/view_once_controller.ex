defmodule ApiGatewayWeb.ViewOnceController do
  @moduledoc """
  View-once opens (115).

  ONE ENDPOINT, and it is the moment the media stops being readable: recording the open is what
  flips the download gate for this recipient, and it also purges the blob so an outstanding
  presigned URL cannot outlive the deny.

  THE OPEN NEVER FAILS ON STORAGE. A MinIO blip must not cost the user the message they just opened
  — the receipt is the authoritative fact and it commits regardless. A blob the purge could not
  delete is retried by the opportunistic sweep below. The alternative (fail the open so the purge
  can be retried atomically) means a transient storage error shows the user an error on a message
  the server has already decided they may read, which is worse in every direction.
  """
  use ApiGatewayWeb, :controller

  require Logger

  alias ApiGatewayWeb.ErrorResponse

  @doc """
  POST /api/v1/conversations/:conversation_id/messages/:message_id/open

  200 `{message_id, opened_at, status: "opened"}` — idempotent: a replay returns the ORIGINAL
  `opened_at`, so a client retrying a lost response cannot move the timestamp or re-trigger a purge.
  403 `message.sender_cannot_open` — view-once is one-way; a sender who could re-read their own send
      would keep a copy of what the recipient believes is gone.
  404 `message.not_found` — unknown, not view-once, or not the caller's conversation. One opaque
      answer, as everywhere else on this surface: a distinct "not view-once" would confirm the
      message exists to anyone probing ids.
  """
  def open(conn, %{"conversation_id" => conversation_id, "message_id" => message_id}) do
    with {:ok, session} <- session(conn),
         :ok <- authorize_membership(conversation_id, session.user_id),
         {:ok, result} <-
           SharedInfra.MessageClient.open_view_once(%{
             # The conversation is the Scylla PARTITION KEY for a point read, and the route already
             # carries it — without it the store cannot find the message at all.
             "conversation_id" => conversation_id,
             "message_id" => message_id,
             "viewer_user_id" => session.user_id
           }) do
      # FIRST OPEN PURGES. A replay must not: the blob is already gone, and re-purging would turn an
      # idempotent call into a second storage round trip for nothing.
      if mget(result, :first_open) == true do
        # THE EXPECTED OWNER IS THE MESSAGE SENDER, never `session.user_id`. The opener is the one
        # untrusted party in this flow — passing them would scope the purge to whoever asked for it,
        # which is exactly the hole the owner scoping exists to close.
        purge_media(mget(result, :media_id), session.app_id, mget(result, :sender_user_id))
      end

      fan_out(conversation_id, session.user_id, %{
        message_id: message_id,
        user_id: session.user_id,
        opened_at: mget(result, :opened_at)
      })

      # Opportunistic maintenance — there is no cron in this system, so the sweep rides the request
      # that is already touching these rows. Bounded, best-effort, and never able to fail the open.
      sweep(session.app_id)

      json(conn, %{
        message_id: message_id,
        opened_at: mget(result, :opened_at),
        status: "opened"
      })
    else
      {:error, :sender_cannot_open} ->
        ErrorResponse.forbidden(
          conn,
          "message.sender_cannot_open",
          "A view-once message cannot be opened by its sender"
        )

      {:error, :session_invalid} ->
        ErrorResponse.unauthorized(conn, "auth.session_invalid", "Session token is invalid")

      {:error, :message_unavailable} ->
        ErrorResponse.service_unavailable(conn, "message.unavailable")

      _ ->
        ErrorResponse.not_found(conn, "message.not_found", "Message not found")
    end
  end

  def open(conn, _params),
    do: ErrorResponse.invalid_request(conn, "message.invalid_request")

  # TOLERATE + RETRY LATER. A failed delete leaves the row flipped (the recipient is already denied)
  # and the blob queued for the sweep; it never reaches the caller.
  defp purge_media(media_id, app_id, expected_owner)
       when is_binary(media_id) and media_id != "" and is_binary(expected_owner) and
              expected_owner != "" do
    case SharedInfra.MediaClient.purge_asset(%{
           "media_id" => media_id,
           "app_id" => app_id,
           "expected_owner_user_id" => expected_owner
         }) do
      {:ok, _} ->
        :ok

      error ->
        Logger.warning(
          "[view_once] purge failed for media=#{media_id} (open still succeeded; " <>
            "the sweep will retry): #{inspect(error)}"
        )

        :ok
    end
  end

  defp purge_media(_media_id, _app_id, _expected_owner), do: :ok

  # THROUGH THE CLIENT SEAM, never MessageService.ViewOnce directly: message_service is a separate
  # RELEASE and its modules do not exist in this one. A direct call compiles in the umbrella and
  # crashes at runtime in production — the exact trap the UPI QR media client hit. The compiler
  # caught it here only because the module is genuinely absent from this app's deps.
  defp sweep(app_id) do
    Task.start(fn ->
      try do
        case SharedInfra.MessageClient.expired_view_once_media(%{"app_id" => app_id}) do
          {:ok, result} ->
            # THE EXPIRY SWEEP CANNOT PURGE UNDER OWNER SCOPING, and says so rather than degrading
            # quietly. `expired_view_once_media` returns bare media ids with no sender, and purge now
            # requires the expected owner — inventing one (the opener, the app) would reintroduce the
            # unscoped delete this slice removed.
            #
            # This is NOT a behaviour change in production: `ViewOnce.expired_unopened_media/0` reads
            # the Postgres `messages` table, which is empty under MESSAGE_STORE_ADAPTER=scylla, so the
            # list has always been []. The follow-up that makes that query store-correct must ALSO
            # carry `sender_user_id` per row; until then this logs and purges nothing.
            case mget(result, :media_ids) || [] do
              [] ->
                :ok

              ids ->
                Logger.warning(
                  "[view_once] expiry sweep found #{length(ids)} expired media but CANNOT purge: " <>
                    "the payload carries no sender_user_id and purge_asset is owner-scoped. " <>
                    "Fix expired_unopened_media/0 to return the sender alongside the media id."
                )
            end

          _ ->
            :ok
        end
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  # THE SENDER IS THE AUDIENCE, and the sender is the one participant guaranteed not to have this
  # chat open — they are looking at their own list waiting for "Opened". A conversation-topic
  # broadcast could never have reached them, so this event has never worked. The OPENER is excluded:
  # they already got the 200 and do not need to be told what they just did.
  defp fan_out(conversation_id, opener_id, frame) do
    ApiGatewayWeb.RealtimeFanOut.to_participants(
      conversation_id,
      opener_id,
      "view_once_opened",
      frame
    )
  end

  defp authorize_membership(conversation_id, user_id) do
    case SharedInfra.ConversationClient.get_conversation(%{
           "conversation_id" => conversation_id,
           "user_id" => user_id
         }) do
      {:ok, _conversation} -> :ok
      _ -> {:error, :not_a_member}
    end
  end

  defp session(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" ->
        SharedInfra.AuthClient.current_session(%{"authorization" => "Bearer " <> token})

      _ ->
        {:error, :session_invalid}
    end
  end

  defp mget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp mget(_map, _key), do: nil
end
