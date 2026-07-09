defmodule ApiGatewayWeb.V1.ConversationAuthz do
  @moduledoc """
  The single authorization gate for every conversation-scoped public `/v1` route. Replaces the old
  tenant-ONLY `conversation_in_app/2` (an `(app_id, id)` predicate) that let any end-user JWT read or
  write ANY conversation in its app.

  Two actors, keyed on whether the request carries a user identity (`:v1_user_id` — V1Auth sets it iff
  the credential is an end-user JWT):

    * app actor (secret key, no user_id) → TENANT scope only (`get_conversation_app`). A server acts for
      the whole app; no membership requirement. Unchanged, by design.
    * end-user actor (JWT, has user_id) → tenant AND membership (`get_conversation` with the user_id runs
      `fetch_active_participant`, `left_at IS NULL`). Acting as ONE user → must be an active participant.

  Keying on user_id presence (not the `:v1_actor` atom) is deliberate: a request carrying a user identity
  can NEVER fall through to the permissive tenant-only path.

  EVERY failure — cross-tenant id, unknown id, or a non-participant — collapses to `{:error, :not_found}`
  so the caller returns a 404 with a generic body. We never return 403 and never confirm that another
  tenant's (or another user's) conversation exists.
  """

  alias SharedInfra.ConversationClient

  @doc """
  Authorize the calling `/v1` actor for `conversation_id`. Returns `{:ok, conversation}` (the underlying
  service shape — callers that render a body must project it to a safe /v1 shape) or `{:error, :not_found}`.
  """
  @spec authorize_conversation(Plug.Conn.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def authorize_conversation(conn, conversation_id) do
    app_id = conn.assigns[:v1_app_id]

    case conn.assigns[:v1_user_id] do
      user_id when is_binary(user_id) and user_id != "" ->
        authorize_end_user(conversation_id, app_id, user_id)

      _ ->
        authorize_app(conversation_id, app_id)
    end
  end

  # App actor: the tenant `(app_id, id)` predicate IS the isolation boundary — cross-tenant OR unknown
  # both surface as :not_found (no existence reveal). No membership check (a server acts app-wide).
  defp authorize_app(conversation_id, app_id) do
    case ConversationClient.get_conversation_app(%{
           "conversation_id" => conversation_id,
           "app_id" => app_id
         }) do
      {:ok, conversation} -> {:ok, conversation}
      _ -> {:error, :not_found}
    end
  end

  # End-user actor: membership via get_conversation (fetch_active_participant → :conversation_forbidden
  # for a non-participant, :conversation_not_found for a missing/cross-tenant id — BOTH map to 404). The
  # `app_id` pin is defence in depth: membership is already transitively app-scoped (a user_id belongs to
  # exactly one app), but we still refuse to serve a conversation whose app_id isn't the caller's.
  defp authorize_end_user(conversation_id, app_id, user_id) do
    case ConversationClient.get_conversation(%{
           "conversation_id" => conversation_id,
           "user_id" => user_id
         }) do
      {:ok, %{app_id: ^app_id} = conversation} -> {:ok, conversation}
      _ -> {:error, :not_found}
    end
  end
end
