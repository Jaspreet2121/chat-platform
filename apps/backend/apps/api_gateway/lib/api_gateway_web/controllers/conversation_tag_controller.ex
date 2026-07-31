defmodule ApiGatewayWeb.ConversationTagController do
  @moduledoc """
  CONVERSATION TAGS — user-defined lists over the caller's own conversations (WhatsApp "Lists").

  Everything here is OWNER-SCOPED by the session, never by a client-supplied id: `owner_user_id` comes
  from `current_session`, so a caller can only ever read or write their own tags. Another user's tag is
  `tag_not_found` — never a 403, which would confirm it exists.

  ASSIGNMENT broadcasts `conversation_updated` with the `:pref` trigger to the caller's OWN devices
  (`only: [user_id]`), reusing the machinery archive/pin/mute/clear/auto-delete already use rather than
  adding an event. That works without a new payload because the inbox row itself carries `tag_ids`:
  the broadcast recomputes the row after the write, so the frame already describes the new state.

  Tag DEFINITIONS (name/colour/position) are NOT broadcast — they are at most 20 rows that change
  rarely, and a client refetches `GET /conversations/tags` when it needs them.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  @tag_limit 20

  # --- tag CRUD -----------------------------------------------------------------------------------

  def create(conn, params) do
    with_owner(conn, fn owner ->
      SharedInfra.ConversationClient.create_tag(%{
        "owner_user_id" => owner.user_id,
        "app_id" => owner.app_id,
        "name" => params["name"],
        "color" => params["color"]
      })
    end)
  end

  def index(conn, _params) do
    with_owner(conn, fn owner ->
      SharedInfra.ConversationClient.list_tags(%{"owner_user_id" => owner.user_id})
    end)
  end

  def update(conn, %{"tag_id" => tag_id} = params) do
    with_owner(conn, fn owner ->
      SharedInfra.ConversationClient.update_tag(%{
        "owner_user_id" => owner.user_id,
        "tag_id" => tag_id,
        "name" => params["name"],
        "color" => params["color"],
        "position" => params["position"]
      })
    end)
  end

  def delete(conn, %{"tag_id" => tag_id}) do
    with_owner(conn, fn owner ->
      SharedInfra.ConversationClient.delete_tag(%{
        "owner_user_id" => owner.user_id,
        "tag_id" => tag_id
      })
    end)
  end

  # --- assignment (broadcasts :pref) ---------------------------------------------------------------

  def assign(conn, %{"conversation_id" => conversation_id, "tag_id" => tag_id}) do
    tag_mutation(conn, conversation_id, fn owner ->
      SharedInfra.ConversationClient.assign_tag(%{
        "owner_user_id" => owner.user_id,
        "tag_id" => tag_id,
        "conversation_id" => conversation_id
      })
    end)
  end

  def unassign(conn, %{"conversation_id" => conversation_id, "tag_id" => tag_id}) do
    tag_mutation(conn, conversation_id, fn owner ->
      SharedInfra.ConversationClient.unassign_tag(%{
        "owner_user_id" => owner.user_id,
        "tag_id" => tag_id,
        "conversation_id" => conversation_id
      })
    end)
  end

  # --- plumbing -----------------------------------------------------------------------------------

  defp with_owner(conn, operation) do
    with {:ok, owner} <- session_owner(conn),
         {:ok, response} <- operation.(owner) do
      json(conn, response)
    else
      error -> handle_error(conn, error)
    end
  end

  # Same shape as ConversationController.pref_mutation/3: do the write, then recompute + broadcast the
  # caller's own inbox row. `only: [user_id]` because a tag is invisible to every other participant.
  defp tag_mutation(conn, conversation_id, operation) do
    with {:ok, owner} <- session_owner(conn),
         {:ok, response} <- operation.(owner) do
      ApiGatewayWeb.ConversationBroadcast.broadcast_updated(
        conversation_id,
        owner.user_id,
        :pref,
        only: [owner.user_id]
      )

      json(conn, response)
    else
      error -> handle_error(conn, error)
    end
  end

  defp session_owner(conn) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}) do
      {:ok, %{user_id: session.user_id, app_id: session_app(session)}}
    end
  end

  defp session_app(session), do: Map.get(session, :app_id) || Map.get(session, "app_id")

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> _token = authorization] -> {:ok, authorization}
      _ -> {:error, :session_invalid}
    end
  end

  defp handle_error(conn, {:error, :session_invalid}),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Invalid or expired session")

  defp handle_error(conn, {:error, :auth_unavailable}),
    do: ErrorResponse.service_unavailable(conn, "auth.unavailable")

  defp handle_error(conn, {:error, :conversation_unavailable}),
    do: ErrorResponse.service_unavailable(conn, "conversation.unavailable")

  defp handle_error(conn, {:error, :not_participant}),
    do: ErrorResponse.forbidden(conn, "conversation.not_participant", "Not a participant")

  # A tag that is not the caller's is INDISTINGUISHABLE from one that does not exist — 404, never 403.
  defp handle_error(conn, {:error, :tag_not_found}),
    do: ErrorResponse.not_found(conn, "conversations.tag_not_found", "Tag not found")

  defp handle_error(conn, {:error, :tag_name_taken}),
    do:
      ErrorResponse.invalid_request_with(
        conn,
        "conversations.tag_name_taken",
        "You already have a tag with that name",
        %{}
      )

  defp handle_error(conn, {:error, :tag_limit}),
    do:
      ErrorResponse.invalid_request_with(
        conn,
        "conversations.tag_limit",
        "Too many tags",
        %{limit: @tag_limit}
      )

  defp handle_error(conn, _other),
    do: ErrorResponse.invalid_request(conn, "conversations.tag_invalid")
end
