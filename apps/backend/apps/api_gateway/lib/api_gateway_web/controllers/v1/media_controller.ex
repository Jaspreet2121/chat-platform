defmodule ApiGatewayWeb.V1.MediaController do
  @moduledoc """
  Public `/v1` media: presigned upload → complete → presigned download. SAME authorization model as the
  first-party `/api/v1/media/*` (server-generated object_key, row-resolved keys, purpose-based download
  authz) but under `V1Auth` actor rules instead of `current_session`, and NEVER returning `object_key`
  (the first-party route still does for legacy frontend reasons; `/v1` is new — the wart stops here).

  Two actors (V1Auth → `:v1_app_id`, `:v1_user_id`):

    * `:app` (secret key) — acts for the whole tenant. Conversation scope is tenant-only; the owner of a
      server-initiated upload is named by an external id (`owner`), resolved like MessageController's
      `sender`. Completion + download are tenant-scoped, no membership/owner check.
    * `:end_user` (JWT) — acts as one user. `owner_user_id` = the caller; membership (upload/download) and
      ownership (complete) are required. Every failure collapses to 404 — never 403, never an existence
      reveal (download/complete); a caller ASSERTING a media_id they can't own on upload → 400.

  Conversation authorization is delegated to `ConversationAuthz` (app→tenant, end_user→membership); the
  download purpose rule is the shared `ApiGatewayWeb.MediaAuthz` (identical to the first-party controller).
  """

  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse
  alias ApiGatewayWeb.MediaAuthz
  alias ApiGatewayWeb.V1.ConversationAuthz
  alias SharedInfra.MediaClient

  @purposes ["message", "user_avatar", "group_avatar"]

  # POST /v1/media/uploads
  def create_upload(conn, params) do
    app_id = conn.assigns.v1_app_id

    with {:ok, purpose} <- fetch_purpose(params),
         {:ok, owner_user_id} <- resolve_owner(conn, app_id, params),
         :ok <- authorize_upload_conversation(conn, purpose, params["conversation_id"]),
         {:ok, response} <-
           MediaClient.create_upload(%{
             "app_id" => app_id,
             "owner_user_id" => owner_user_id,
             "purpose" => purpose,
             "conversation_id" => params["conversation_id"],
             "filename" => params["filename"],
             "content_type" => params["content_type"],
             "size_bytes" => params["size_bytes"]
           }) do
      conn |> put_status(:created) |> json(upload_view(response))
    else
      # A non-member (end_user) conversation → 404, no existence reveal.
      {:error, :not_found} -> not_found(conn)
      {:error, :media_too_large} -> too_large(conn)
      {:error, :media_unavailable} -> service_unavailable(conn)
      # Bad/absent purpose, missing conversation for a message/group_avatar, or an :app owner that doesn't
      # resolve to a user in this app → 400 (the caller supplied an invalid request, not a hidden resource).
      _ -> invalid_request(conn)
    end
  end

  # POST /v1/media/uploads/:media_id/complete
  def complete_upload(conn, %{"media_id" => media_id}) do
    app_id = conn.assigns.v1_app_id

    with {:ok, owner_user_id} <- complete_owner(conn, app_id, media_id),
         {:ok, response} <-
           MediaClient.complete_upload(%{
             "media_id" => media_id,
             "owner_user_id" => owner_user_id,
             "app_id" => app_id
           }) do
      json(conn, complete_view(response))
    else
      # The REAL uploaded bytes exceed the cap (verified by a HEAD at complete — the claimed size_bytes is
      # advisory). The object has been deleted and the asset is NOT ready. 413, the same code create_upload
      # already returns for an over-cap CLAIM.
      {:error, :media_too_large} -> too_large(conn)
      # The presigned PUT never happened — nothing to complete.
      {:error, :upload_not_found} -> not_found(conn)
      # Could not verify the object (storage unreachable). We FAIL CLOSED and do not mark it ready; this is
      # transient, so 503 tells the client to simply call complete again.
      {:error, :verify_failed} -> service_unavailable(conn)
      # Unknown / cross-tenant / wrong-owner (end_user) → opaque 404. Completing a `ready` asset succeeds
      # (idempotent). Service failures also collapse to 404 here (no partial-state reveal).
      _ -> not_found(conn)
    end
  end

  # GET /v1/media/:media_id/download  (any client `object_key` param is ignored — the URL signs the row's key)
  def download(conn, %{"media_id" => media_id}) do
    app_id = conn.assigns.v1_app_id

    with {:ok, asset} <- MediaClient.get_asset(%{"media_id" => media_id, "app_id" => app_id}),
         :ok <- authorize_download(conn, media_id, asset),
         {:ok, response} <-
           MediaClient.get_download_url(%{"media_id" => media_id, "app_id" => app_id}) do
      json(conn, download_view(media_id, response))
    else
      # not_found (unknown/cross-tenant asset), not_a_member, or any other failure → opaque 404.
      _ -> not_found(conn)
    end
  end

  # --- actor resolution ---------------------------------------------------------------------------

  # end_user → the caller owns the upload. :app → the server names the owner by external id (`owner`),
  # resolved within the app exactly like MessageController.resolve_sender resolves `sender`.
  defp resolve_owner(conn, app_id, params) do
    cond do
      is_binary(conn.assigns[:v1_user_id]) and conn.assigns.v1_user_id != "" ->
        {:ok, conn.assigns.v1_user_id}

      is_binary(params["owner"]) and params["owner"] != "" ->
        case SharedInfra.AuthClient.resolve_external_user(%{
               "app_id" => app_id,
               "external_id" => params["owner"]
             }) do
          {:ok, %{user_id: user_id}} when is_binary(user_id) and user_id != "" -> {:ok, user_id}
          _ -> {:error, :unresolved_owner}
        end

      true ->
        {:error, :unresolved_owner}
    end
  end

  # Conversation-scoped purposes (message, group_avatar) require a conversation_id and authorize it via
  # ConversationAuthz: app → tenant scope, end_user → active membership (non-member → :not_found → 404).
  defp authorize_upload_conversation(conn, purpose, conversation_id)
       when purpose in ["message", "group_avatar"] do
    if is_binary(conversation_id) and conversation_id != "" do
      case ConversationAuthz.authorize_conversation(conn, conversation_id) do
        {:ok, _conversation} -> :ok
        {:error, :not_found} -> {:error, :not_found}
      end
    else
      {:error, :conversation_required}
    end
  end

  defp authorize_upload_conversation(_conn, _purpose, _conversation_id), do: :ok

  # end_user → owner MUST be the caller (complete_upload's owner pin refuses a foreign/cross-tenant id → 404).
  # :app → tenant scope: resolve the row's own owner (get_asset is (media_id, app_id)-scoped) and complete
  # with it. Safe — the app can only complete uploads in its OWN tenant, and completing one's own tenant's
  # upload is the intended server action; it can't touch another tenant's asset (get_asset would 404).
  defp complete_owner(conn, app_id, media_id) do
    case conn.assigns[:v1_user_id] do
      user_id when is_binary(user_id) and user_id != "" ->
        {:ok, user_id}

      _ ->
        case MediaClient.get_asset(%{"media_id" => media_id, "app_id" => app_id}) do
          {:ok, asset} ->
            case aget(asset, :owner_user_id) do
              owner when is_binary(owner) and owner != "" -> {:ok, owner}
              _ -> {:error, :not_found}
            end

          _ ->
            {:error, :not_found}
        end
    end
  end

  # end_user → the shared by-purpose rule (membership / owner-only). :app → tenant scope only (get_asset
  # already pinned app_id, so an authenticated app credential is sufficient).
  defp authorize_download(conn, media_id, asset) do
    case conn.assigns[:v1_user_id] do
      user_id when is_binary(user_id) and user_id != "" ->
        MediaAuthz.authorize_download(media_id, asset, user_id)

      _ ->
        :ok
    end
  end

  # --- views (never expose object_key) ------------------------------------------------------------

  defp upload_view(response) do
    %{
      media_id: mget(response, :media_id),
      upload_url: mget(response, :upload_url),
      expires_at: mget(response, :expires_at),
      # A freshly-created upload is always "created" (the service's upload_response omits status).
      status: "created"
    }
  end

  defp complete_view(response),
    do: %{media_id: mget(response, :media_id), status: mget(response, :status)}

  defp download_view(media_id, response) do
    %{
      media_id: media_id,
      download_url: mget(response, :download_url),
      expires_at: mget(response, :expires_at),
      mime_type: mget(response, :mime_type)
    }
  end

  # --- helpers ------------------------------------------------------------------------------------

  defp fetch_purpose(params) do
    case params["purpose"] do
      purpose when purpose in @purposes -> {:ok, purpose}
      _ -> {:error, :invalid_purpose}
    end
  end

  defp mget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp mget(_map, _key), do: nil

  defp aget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp aget(_map, _key), do: nil

  defp not_found(conn), do: ErrorResponse.not_found(conn, "v1.not_found", "Not found")
  defp invalid_request(conn), do: ErrorResponse.invalid_request(conn, "v1.invalid_request")

  defp too_large(conn),
    do: ErrorResponse.payload_too_large(conn, "v1.media_too_large", "File is too large.")

  defp service_unavailable(conn), do: ErrorResponse.service_unavailable(conn, "v1.unavailable")
end
