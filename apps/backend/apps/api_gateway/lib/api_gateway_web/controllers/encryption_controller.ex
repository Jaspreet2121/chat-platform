defmodule ApiGatewayWeb.EncryptionController do
  @moduledoc """
  Secret-chat toggle (108; two-party OFF in 118): POST /api/v1/conversations/:id/encryption.

      {"enabled": true}                   ON — either participant, immediate; clears the explicit-off
                                          marker and any pending OFF request. A real flip also purges
                                          the conversation's search-only copy (108's promise).
      {"enabled": false}                  OFF — two-party. No pending request: RECORDS one by the
                                          caller. Pending from the OTHER member: ACCEPTS it — the only
                                          call that ever flips to plain. Pending from the caller:
                                          idempotent.
      {"enabled": false, "cancel": true}  the requester withdraws their own pending request.

  Every 200 carries the same five keys {enabled, e2ee_disabled, off_requested, requested_by,
  requested_at}. Every REAL change writes a plaintext SYSTEM message {kind: "encryption", state, by}
  through the normal message path (protocol state, never user content — plaintext by design) and
  broadcasts conversation_encryption_changed to both members' user topics; an idempotent call emits
  nothing. Membership, direct-only, keys and the two-party rule are all enforced by the store
  (ConversationService.Encryption) — this half only maps results to the wire.
  """
  use ApiGatewayWeb, :controller

  require Logger

  alias ApiGatewayWeb.ErrorResponse
  alias ApiGatewayWeb.SecretChatEvents

  # The store's `change` markers — each one is a system-message state verbatim.
  @changes ["enabled", "off_requested", "disabled", "off_cancelled"]

  @doc """
  The conversation DETAIL's 118 keys. Spelled here as atoms so the HTTP adapter rehydrates them
  like every other detail key — `String.to_existing_atom/1` only knows atoms some loaded module
  names, and a key it cannot name stays a string.
  """
  def detail_keys, do: [:e2ee_disabled, :e2ee_off_pending]

  def update(conn, %{"conversation_id" => conversation_id} = params) do
    with {:ok, session} <- session(conn),
         {:ok, result} <-
           SharedInfra.ConversationClient.set_encryption(%{
             "conversation_id" => conversation_id,
             "user_id" => session.user_id,
             "enabled" => Map.get(params, "enabled"),
             "cancel" => Map.get(params, "cancel")
           }) do
      emit_change(conversation_id, session.user_id, result)
      json(conn, response(result))
    else
      error -> handle_error(conn, error)
    end
  end

  def update(conn, _params), do: ErrorResponse.invalid_request(conn, "secret.invalid")

  # The effects of a REAL change, in the ON pattern: system message → frame → (ON only) purge.
  defp emit_change(conversation_id, actor_id, result) do
    case mget(result, :change) do
      state when state in @changes ->
        SecretChatEvents.system_message(conversation_id, actor_id, %{
          "kind" => "encryption",
          "state" => state,
          "by" => actor_id
        })

        frame = frame(conversation_id, result)

        for member <- mget(result, :member_ids) || [] do
          ApiGatewayWeb.Endpoint.broadcast(
            "user:" <> member,
            "conversation_encryption_changed",
            frame
          )
        end

        if state == "enabled", do: purge_search_index(conversation_id)

        :ok

      _ ->
        :ok
    end
  end

  # The live frame mirrors the detail response's three encryption fields, so a client can apply it
  # without a refetch: enabled (= detail `secret`), e2ee_disabled, e2ee_off_pending.
  defp frame(conversation_id, result) do
    %{
      "type" => "conversation_encryption_changed",
      "conversation_id" => conversation_id,
      "enabled" => mget(result, :enabled) == true,
      "e2ee_disabled" => mget(result, :e2ee_disabled) == true,
      "e2ee_off_pending" => pending_wire(result)
    }
  end

  defp pending_wire(result) do
    case mget(result, :off_pending) do
      %{} = pending ->
        %{
          "requested_by" => mget(pending, :requested_by),
          "requested_at" => mget(pending, :requested_at)
        }

      _ ->
        nil
    end
  end

  defp response(result) do
    pending = mget(result, :off_pending)

    %{
      enabled: mget(result, :enabled) == true,
      e2ee_disabled: mget(result, :e2ee_disabled) == true,
      off_requested: is_map(pending),
      requested_by: pending && mget(pending, :requested_by),
      requested_at: pending && mget(pending, :requested_at)
    }
  end

  # 108's promise, kept on every real ON: the plaintext indexed while the chat was plain leaves the
  # search-only copy. Best-effort — a failure is logged at ERROR and never blocks the flip.
  defp purge_search_index(conversation_id) do
    case SharedInfra.MessageClient.purge_search_index(%{"conversation_id" => conversation_id}) do
      {:ok, _} ->
        :ok

      other ->
        Logger.error(
          "[secret] search purge FAILED conv=#{conversation_id} reason=#{inspect(other)}"
        )
    end
  rescue
    error ->
      Logger.error("[secret] search purge RAISED conv=#{conversation_id} error=#{inspect(error)}")
  end

  defp session(conn) do
    with ["Bearer " <> token] when token != "" <- get_req_header(conn, "authorization"),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => "Bearer " <> token}) do
      {:ok, session}
    else
      _ -> {:error, :session_invalid}
    end
  end

  defp handle_error(conn, {:error, :session_invalid}),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Invalid or expired session")

  defp handle_error(conn, {:error, :secret_not_supported}),
    do:
      ErrorResponse.unprocessable_entity(
        conn,
        "secret.not_supported",
        "Secret chats are 1:1 only"
      )

  # A conversation service still on the one-way build answers this for enabled:false during a
  # rolling deploy; kept so the atom stays nameable on the wire until that window is closed.
  defp handle_error(conn, {:error, :secret_cannot_disable}),
    do:
      ErrorResponse.unprocessable_entity(
        conn,
        "secret.cannot_disable",
        "A secret chat cannot be switched back — start a new chat instead"
      )

  defp handle_error(conn, {:error, :secret_not_requester}),
    do:
      ErrorResponse.forbidden(
        conn,
        "secret.not_requester",
        "Only the member who asked to turn encryption off can cancel that request"
      )

  defp handle_error(conn, {:error, {:secret_peer_keys_missing, missing}}) do
    ErrorResponse.conflict_with(
      conn,
      "secret.peer_keys_missing",
      "Both sides need registered device keys first",
      %{missing_user_ids: missing}
    )
  end

  # Unknown, non-member and cross-tenant are ONE store answer and ONE body — never a 403.
  defp handle_error(conn, {:error, :conversation_not_found}),
    do: ErrorResponse.not_found(conn, "conversation.not_found", "Conversation not found")

  defp handle_error(conn, {:error, :conversation_unavailable}),
    do: ErrorResponse.service_unavailable(conn, "secret.unavailable")

  defp handle_error(conn, {:error, :secret_invalid}),
    do: ErrorResponse.invalid_request(conn, "secret.invalid")

  defp handle_error(conn, _), do: ErrorResponse.invalid_request(conn, "secret.invalid")

  defp mget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp mget(_, _), do: nil
end
