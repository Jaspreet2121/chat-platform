defmodule ApiGatewayWeb.PinController do
  @moduledoc """
  PINNED MESSAGES (092) — a capped number per conversation, visible to every participant.

  Distinct from pinning a CONVERSATION (076, `conversation_participants.pinned_at`), which is a
  per-user inbox preference. Two features, one word; see the 092 migration header.

  ## Who can pin — mirrors the existing tiers, does not invent one

  Groups: OWNER + ADMIN. Pinning mutates a SHARED view, which is the tier that already owns group
  profile and group settings. It is deliberately NOT the owner-only tier: that one is reserved for
  MEMBERSHIP changes (`add_participant` uses `require_owner`), and the invite-link slice's reasoning
  for it was specifically about who may alter the room's membership — which does not extend to what
  is displayed in it.

  Direct chats: EITHER participant. There are no roles in a 1:1.

  The owner+admin predicate is `Conversations.ensure_owner_or_admin/1` (renamed in this slice from
  `ensure_owner`, which asserted the opposite of what it does). The genuinely owner-only gate is
  `Participants.require_owner/2`.

  ## Transport

  The pinned set rides the EXISTING `conversation_updated` event under a new trigger tag, `:pin`,
  fanned to every active participant. It deliberately does NOT reuse `:pref`: that trigger is
  documented as `only: [the acting user]` because archive/pin-a-conversation is invisible to everyone
  else — reusing it here would deliver the change to the pinner alone and nobody else's pinned bar
  would move.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  # PUT /api/v1/conversations/:conversation_id/messages/:message_id/pin
  def create(conn, %{"conversation_id" => conversation_id, "message_id" => message_id}) do
    with {:ok, session} <- session(conn),
         :ok <- authorize_pin(conversation_id, session.user_id),
         {:ok, _result} <-
           SharedInfra.MessageClient.pin_message(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id,
             "user_id" => session.user_id
           }) do
      broadcast_pin(conversation_id, session.user_id)
      json(conn, %{conversation_id: conversation_id, message_id: message_id, pinned: true})
    else
      error -> handle_error(conn, error)
    end
  end

  def create(conn, _params), do: ErrorResponse.invalid_request(conn, "pin.invalid_request")

  # DELETE /api/v1/conversations/:conversation_id/messages/:message_id/pin
  def delete(conn, %{"conversation_id" => conversation_id, "message_id" => message_id}) do
    with {:ok, session} <- session(conn),
         :ok <- authorize_pin(conversation_id, session.user_id),
         {:ok, _result} <-
           SharedInfra.MessageClient.unpin_message(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id
           }) do
      broadcast_pin(conversation_id, session.user_id)
      json(conn, %{conversation_id: conversation_id, message_id: message_id, pinned: false})
    else
      error -> handle_error(conn, error)
    end
  end

  def delete(conn, _params), do: ErrorResponse.invalid_request(conn, "pin.invalid_request")

  # GET /api/v1/conversations/:conversation_id/pins — MASKED for the caller (see MessageService.Pins).
  def index(conn, %{"conversation_id" => conversation_id}) do
    with {:ok, session} <- session(conn),
         :ok <- ensure_member(conversation_id, session.user_id),
         {:ok, %{pins: pins}} <-
           SharedInfra.MessageClient.list_pins(%{
             "conversation_id" => conversation_id,
             "user_id" => session.user_id
           }) do
      json(conn, %{pinned_messages: pins})
    else
      error -> handle_error(conn, error)
    end
  end

  def index(conn, _params), do: ErrorResponse.invalid_request(conn, "pin.invalid_request")

  # --- authorization ------------------------------------------------------------------------------

  # Groups: owner/admin. Direct: any active participant. A non-participant fails as :not_a_member
  # (404-shaped) rather than :pin_forbidden, so pinning cannot be used to probe whether a
  # conversation exists.
  defp authorize_pin(conversation_id, user_id) do
    case SharedInfra.ConversationClient.get_conversation(%{
           "conversation_id" => conversation_id,
           "user_id" => user_id
         }) do
      {:ok, conversation} ->
        cond do
          cget(conversation, :type) != "group" -> :ok
          participant_role(conversation, user_id) in ["owner", "admin"] -> :ok
          true -> {:error, :pin_forbidden}
        end

      {:error, :conversation_unavailable} ->
        {:error, :conversation_unavailable}

      _ ->
        {:error, :not_a_member}
    end
  end

  defp ensure_member(conversation_id, user_id) do
    case SharedInfra.ConversationClient.get_conversation(%{
           "conversation_id" => conversation_id,
           "user_id" => user_id
         }) do
      {:ok, _conversation} -> :ok
      {:error, :conversation_unavailable} -> {:error, :conversation_unavailable}
      _ -> {:error, :not_a_member}
    end
  end

  defp participant_role(conversation, user_id) do
    (cget(conversation, :participants) || [])
    |> Enum.find(fn participant -> cget(participant, :user_id) == user_id end)
    |> case do
      nil -> nil
      participant -> cget(participant, :role)
    end
  end

  # --- transport ----------------------------------------------------------------------------------

  defp broadcast_pin(conversation_id, actor_user_id) do
    ApiGatewayWeb.ConversationBroadcast.broadcast_updated(conversation_id, actor_user_id, :pin)
  end

  # --- plumbing -----------------------------------------------------------------------------------

  defp session(conn) do
    with {:ok, authorization} <- authorization_header(conn) do
      SharedInfra.AuthClient.current_session(%{"authorization" => authorization})
    end
  end

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token = authorization] when token != "" -> {:ok, authorization}
      _ -> {:error, :session_invalid}
    end
  end

  defp cget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp cget(_map, _key), do: nil

  defp handle_error(conn, {:error, :session_invalid}),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Invalid or missing session")

  defp handle_error(conn, {:error, :pin_forbidden}),
    do:
      ErrorResponse.forbidden(
        conn,
        "conversation.pin_forbidden",
        "Only admins can pin messages in this group"
      )

  defp handle_error(conn, {:error, :pin_limit}),
    do:
      conn
      |> put_status(:conflict)
      |> json(%{
        error: %{
          code: "message.pin_limit",
          # Deliberately does NOT restate the cap. The number lives in exactly one place
          # (MessageService.Pins.max_pins/0) and the gateway cannot see that module across the
          # service boundary — copying it here would create a second constant to drift.
          message: "This conversation already has the maximum number of pinned messages",
          correlation_id: SharedInfra.Correlation.get_or_generate()
        }
      })

  defp handle_error(conn, {:error, reason}) when reason in [:not_a_member, :message_not_found],
    do: ErrorResponse.not_found(conn, "message.not_found", "Not found")

  defp handle_error(conn, {:error, unavailable})
       when unavailable in [:conversation_unavailable, :message_unavailable, :auth_unavailable],
       do: ErrorResponse.service_unavailable(conn, "pin.unavailable")

  defp handle_error(conn, _error),
    do: ErrorResponse.invalid_request(conn, "pin.invalid_request")
end
