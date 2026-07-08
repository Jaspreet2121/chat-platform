defmodule ApiGatewayWeb.V1.CallController do
  @moduledoc """
  Public `/v1` call surface (V1a) — LiveKit token + call status for an integrator's END-USER SDK. Requires
  the end-user JWT actor (`v1_actor == :end_user`); a secret-key/app actor is rejected (403
  `v1.end_user_only`, the inverse of the webhook secret-key guard). The first-party internal `/api/v1/calls`
  surface is untouched.

  TENANT ISOLATION: the `calls` table carries no app_id — scope rides on PARTICIPANT MEMBERSHIP. Every
  participant/caller/callee is a `user_id` that AuthClient created per `(app_id, external_id)`, so a call's
  seats belong to exactly one app. V1Auth resolves `v1_user_id` WITHIN `v1_app_id`; authorizing "this user is
  a seat of this call" therefore proves the call belongs to the caller's app. A user of app A is never a seat
  of app B's call → 404 (fail closed, never a cross-tenant existence reveal). We reuse the same CallStore
  logic the internal token endpoint uses (get_call + call_participant? + caller/callee).
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  # POST /v1/calls/:id/token — mint a LiveKit token so the end-user can join call :id (they must be a seat).
  # Same { url, token } shape as the internal endpoint. Not authorized / cross-tenant / missing → 404.
  def token(conn, %{"id" => call_id}) when is_binary(call_id) and call_id != "" do
    with :ok <- require_end_user(conn),
         {:ok, call} <- authorized_call(call_id, conn.assigns.v1_user_id),
         room when is_binary(room) and room != "" <- cget(call, :room_name),
         {:ok, jwt} <-
           SharedInfra.LiveKitToken.create(conn.assigns.v1_user_id, room, name: conn.assigns.v1_user_id) do
      json(conn, %{url: SharedInfra.LiveKitToken.url(), token: jwt})
    else
      {:error, :app_only} -> app_only(conn)
      {:error, :livekit_not_configured} -> ErrorResponse.service_unavailable(conn, "v1.unavailable")
      _ -> not_found(conn)
    end
  end

  def token(conn, _params), do: ErrorResponse.invalid_request(conn, "v1.invalid_request")

  # GET /v1/calls/:id — call status (id/kind/status/type + participant ids), scoped: the caller must be a
  # seat. Cross-tenant / missing → 404.
  def show(conn, %{"id" => call_id}) when is_binary(call_id) and call_id != "" do
    with :ok <- require_end_user(conn),
         {:ok, call} <- authorized_call(call_id, conn.assigns.v1_user_id) do
      json(conn, present_status(call, call_id))
    else
      {:error, :app_only} -> app_only(conn)
      _ -> not_found(conn)
    end
  end

  def show(conn, _params), do: ErrorResponse.invalid_request(conn, "v1.invalid_request")

  # --- helpers -----------------------------------------------------------------------------------

  # /v1 calls require the END-USER JWT (has a user_id). A secret-key/app actor has no user → reject.
  defp require_end_user(conn) do
    if conn.assigns[:v1_actor] == :end_user and is_binary(conn.assigns[:v1_user_id]),
      do: :ok,
      else: {:error, :app_only}
  end

  # Fetch the call ONLY if `user_id` is a seat of it — this IS the tenant seal (see @moduledoc). Any failure
  # (missing / cross-tenant / not authorized) collapses to :not_found → 404, no existence reveal.
  defp authorized_call(call_id, user_id) do
    with {:ok, call} <- SharedInfra.ConversationClient.get_call(%{"call_id" => call_id}),
         true <- seat?(call, call_id, user_id) do
      {:ok, call}
    else
      _ -> {:error, :not_found}
    end
  end

  # Mirrors the internal call_controller's authorize check (kept separate so /api/v1/calls stays UNTOUCHED):
  # group/link calls authorize on a participant row; direct calls on caller/callee.
  defp seat?(call, call_id, user_id) do
    case cget(call, :kind) || "direct" do
      kind when kind in ["group", "link"] ->
        case SharedInfra.ConversationClient.call_participant?(%{
               "call_id" => call_id,
               "user_id" => user_id
             }) do
          {:ok, %{authorized: true}} -> true
          {:ok, %{"authorized" => true}} -> true
          _ -> false
        end

      _ ->
        user_id == cget(call, :caller_id) or user_id == cget(call, :callee_id)
    end
  end

  defp present_status(call, call_id) do
    %{
      id: cget(call, :id),
      kind: cget(call, :kind) || "direct",
      status: cget(call, :status),
      type: cget(call, :type),
      participants: participant_ids(call, call_id)
    }
  end

  # Direct calls have no participant rows → the seats are caller + callee. Group/link calls read the
  # group_call_participants rows.
  defp participant_ids(call, call_id) do
    case cget(call, :kind) || "direct" do
      kind when kind in ["group", "link"] ->
        case SharedInfra.ConversationClient.get_call_with_participants(%{"call_id" => call_id}) do
          {:ok, result} ->
            (cget(result, :participants) || []) |> Enum.map(&cget(&1, :user_id)) |> Enum.reject(&is_nil/1)

          _ ->
            []
        end

      _ ->
        Enum.filter([cget(call, :caller_id), cget(call, :callee_id)], &is_binary/1)
    end
  end

  defp app_only(conn),
    do: ErrorResponse.forbidden(conn, "v1.end_user_only", "This endpoint requires an end-user token")

  defp not_found(conn), do: ErrorResponse.not_found(conn, "v1.not_found", "Not found")

  # Call maps arrive atom-keyed (in-process) or string-keyed (HTTP adapter) — read either. Nil-safe.
  defp cget(nil, _key), do: nil
  defp cget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp cget(_map, _key), do: nil
end
