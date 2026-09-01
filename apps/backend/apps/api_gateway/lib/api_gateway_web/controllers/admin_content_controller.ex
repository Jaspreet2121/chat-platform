defmodule ApiGatewayWeb.AdminContentController do
  @moduledoc """
  IAM Phase 2 — admin content-access (chat message content) for platform oversight.

  `GET /api/v1/admin/conversations/:id/messages`. Entry is gated by `RequireAdmin` (console access —
  any admin role). The RESPONSE depends on the caller's IAM permission:

    * `content.read` (root only) → FULL message content, and EVERY read writes an `audit_logs` row
      (actor, conversation + its tenant `app_id`, message_count, action `"content.read"`). Never
      un-audited.
    * console access WITHOUT `content.read` (admin/moderator/support) → MASKED: safe metadata only
      (message id, sender, type, status, timestamps, content length); body/caption/media/free-form
      metadata are REDACTED to `"[content hidden]"`. Masking is a server-side WHITELIST built before
      serialization — the text never leaves this function for a masked role.
    * no console access → 403 (the scope gate handles it before we get here).

  This deliberately crosses tenant isolation (admin oversight): it skips the gateway membership gate that
  the normal `/api/v1/conversations/:id/messages` path applies (`authorize_membership`). That bypass is
  confined to THIS endpoint, reachable ONLY behind the admin gate + permission branch, and every unmasked
  read is audited. It is NOT exposed on `/v1` or any user-facing path, and no other isolation is weakened.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  @max_limit 200

  # Browsable conversation list (metadata only — no message content), so admins don't type UUIDs. Entry
  # is console access (any admin role); content stays gated + masked when a conversation is opened.
  def conversations(conn, params) do
    case SharedInfra.ConversationClient.admin_list_conversations(%{
           "q" => params["q"],
           "page" => params["page"],
           "app_id" => tenant()
         }) do
      {:ok, data} ->
        json(conn, data)

      {:error, :conversation_unavailable} ->
        ErrorResponse.service_unavailable(conn, "admin.unavailable")

      {:error, _reason} ->
        ErrorResponse.invalid_request(conn, "admin.invalid_request")
    end
  end

  # A given user's conversations (metadata only — who they've chatted with). Console-access gated.
  def user_conversations(conn, %{"id" => user_id}) do
    case SharedInfra.ConversationClient.admin_user_conversations(%{
           "user_id" => user_id,
           "app_id" => tenant()
         }) do
      {:ok, data} ->
        json(conn, data)

      {:error, :conversation_unavailable} ->
        ErrorResponse.service_unavailable(conn, "admin.unavailable")

      {:error, _reason} ->
        ErrorResponse.invalid_request(conn, "admin.invalid_request")
    end
  end

  def messages(conn, %{"id" => conversation_id} = params) do
    session = conn.assigns.admin_session
    unmasked? = "content.read" in (Map.get(session, :permissions) || [])
    app_id = tenant_app_id(conversation_id)

    # FIRST-PARTY ONLY: the console never reads an integrator conversation's content. A conversation outside
    # tenant-zero (or an unknown/unresolvable id) → 404, before any message is fetched or audited.
    cond do
      app_id != tenant() ->
        ErrorResponse.not_found(conn, "admin.not_found", "Not found")

      true ->
        case SharedInfra.MessageClient.list_messages(%{
               "conversation_id" => conversation_id,
               "limit" => limit(params)
             }) do
          {:ok, timeline} ->
            messages = Map.get(timeline, :messages) || Map.get(timeline, "messages") || []
            respond(conn, session, conversation_id, app_id, messages, unmasked?)

          {:error, :message_unavailable} ->
            ErrorResponse.service_unavailable(conn, "admin.unavailable")

          {:error, _reason} ->
            ErrorResponse.invalid_request(conn, "admin.invalid_request")
        end
    end
  end

  # content.read → full content + MANDATORY audit of the access (records that it happened, never the text).
  # Media messages are enriched with a presigned download_url so the viewer can display/play them — the
  # media view is part of the same audited content.read (no separate unaudited path).
  defp respond(conn, session, conversation_id, app_id, messages, true) do
    audit(session, conversation_id, app_id, length(messages), "content.read", false)

    json(conn, %{
      conversation_id: conversation_id,
      app_id: app_id,
      masked: false,
      message_count: length(messages),
      messages: messages |> enrich_all(app_id) |> with_sender_identities()
    })
  end

  # No content.read → masked metadata only + a lighter oversight row. Text is dropped before serialize.
  defp respond(conn, session, conversation_id, app_id, messages, false) do
    masked = messages |> Enum.map(&mask/1) |> with_sender_identities()
    audit(session, conversation_id, app_id, length(masked), "content.view.masked", true)

    json(conn, %{
      conversation_id: conversation_id,
      app_id: app_id,
      masked: true,
      message_count: length(masked),
      messages: masked
    })
  end

  # Presign media download URLs CONCURRENTLY (bounded, ordered). With the HTTP media-client adapter each
  # presign is a gateway→media-service round trip; doing up to 200 sequentially blocked the whole
  # response. A failed/slow presign degrades that one message (no URL) instead of the list.
  # (Lives BELOW both respond/6 clauses so they stay grouped — Elixir warns otherwise, and that warning
  # is fatal under --warnings-as-errors.)
  @enrich_concurrency 16
  @enrich_timeout_ms 5_000
  defp enrich_all(messages, app_id) do
    messages
    |> Task.async_stream(fn message -> enrich_media(message, app_id) end,
      max_concurrency: @enrich_concurrency,
      timeout: @enrich_timeout_ms,
      on_timeout: :kill_task,
      zip_input_on_exit: true,
      ordered: true
    )
    |> Enum.map(fn
      {:ok, enriched} -> enriched
      {:exit, {message, _reason}} -> message
    end)
  end

  # Attach the sender's display_name + phone to each message (ONE batched auth lookup — no N+1) so the
  # admin viewer can show WHO sent it instead of a raw id. Best-effort: a lookup failure leaves ids only.
  # Applied to both masked and unmasked responses (the sender id is already exposed in both).
  defp with_sender_identities(messages) do
    ids =
      messages |> Enum.map(&mget(&1, :sender_user_id)) |> Enum.filter(&is_binary/1) |> Enum.uniq()

    lookup =
      case SharedInfra.AuthClient.list_user_summaries(%{"user_ids" => ids}) do
        {:ok, result} ->
          (Map.get(result, :summaries) || Map.get(result, "summaries") || [])
          |> Map.new(fn s -> {mget(s, :user_id), s} end)

        _ ->
          %{}
      end

    Enum.map(messages, fn m ->
      case Map.get(lookup, mget(m, :sender_user_id)) do
        nil ->
          m

        s ->
          m
          |> Map.put(:sender_display_name, mget(s, :display_name))
          |> Map.put(:sender_phone, mget(s, :phone_number))
      end
    end)
  rescue
    _ -> messages
  end

  # WHITELIST: only safe metadata is copied out; body/caption/media_id/metadata are never included.
  # For media messages the redaction label is type-aware ("[image hidden]" etc.) — the label is derived
  # server-side from the content_type and is the ONLY thing emitted; no URL, media_id or object_key.
  @doc false
  def mask(m) do
    %{
      message_id: mget(m, :message_id),
      sender_user_id: mget(m, :sender_user_id),
      message_type: mget(m, :message_type),
      status: mget(m, :status),
      created_at: mget(m, :created_at),
      edited_at: mget(m, :edited_at),
      deleted_at: mget(m, :deleted_at),
      content_length: byte_size(to_string(mget(m, :body) || "")),
      content: masked_label(m)
    }
  end

  defp masked_label(m) do
    case mget(m, :message_type) do
      "media" ->
        metadata = mget(m, :metadata) || %{}

        content_type =
          to_string(Map.get(metadata, "content_type") || Map.get(metadata, :content_type))

        cond do
          String.starts_with?(content_type, "image/") -> "[image hidden]"
          String.starts_with?(content_type, "audio/") -> "[voice message hidden]"
          String.starts_with?(content_type, "video/") -> "[video hidden]"
          true -> "[media hidden]"
        end

      "location" ->
        "[location hidden]"

      "live_location" ->
        "[live location hidden]"

      _ ->
        "[content hidden]"
    end
  end

  # content.read only: attach a presigned GET download_url to media messages (same signing path the
  # normal chat uses) so the admin viewer can render them. Best-effort — a presign failure leaves the
  # message intact without a URL. Non-media messages pass through untouched.
  # Presign scoped to the ASSET's app_id (the conversation's tenant, resolved by the caller). An admin/root
  # actor is tenant-wide, so the asset's own app is the correct scope. object_key is resolved server-side
  # from the row; the purpose assertion refuses to presign a non-attachment asset. "user_asset" (113)
  # joins it because the /qr slash command sends a server-generated QR as an ordinary media message —
  # moderation must be able to see exactly what was sent. An avatar still cannot be presigned here.
  @doc false
  def enrich_media(m, app_id) do
    media_id = mget(m, :media_id)

    if mget(m, :message_type) == "media" and is_binary(media_id) and is_binary(app_id) do
      case SharedInfra.MediaClient.get_download_url(%{
             "media_id" => media_id,
             "app_id" => app_id,
             "purpose" => ["message", "user_asset"]
           }) do
        {:ok, download} ->
          Map.put(
            m,
            :download_url,
            Map.get(download, :download_url) || Map.get(download, "download_url")
          )

        {:error, _reason} ->
          m
      end
    else
      m
    end
  rescue
    _ -> m
  end

  defp audit(session, conversation_id, app_id, count, action, masked?) do
    SharedInfra.AuthClient.write_audit(%{
      "actor_user_id" => Map.get(session, :user_id),
      "action" => action,
      "target_type" => "conversation",
      "target_id" => conversation_id,
      "metadata" => %{"app_id" => app_id, "message_count" => count, "masked" => masked?}
    })
  end

  # The conversation's tenant, WITHOUT a membership check (admin oversight). Best-effort: audit still
  # fires even if the tenant lookup is unavailable.
  defp tenant_app_id(conversation_id) do
    case SharedInfra.ConversationClient.get_conversation_app(%{
           "conversation_id" => conversation_id
         }) do
      {:ok, %{app_id: app_id}} -> app_id
      {:ok, map} when is_map(map) -> Map.get(map, "app_id")
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # The console's tenant — FIRST-PARTY ONLY (tenant-zero, the single source in SharedInfra.Tenancy). Never
  # relax this to read another tenant's content; a cross-tenant OPERATIONS view (per-app counts/usage) is a
  # SEPARATE future route (`/api/v1/admin/platform/*`) with its OWN controller containing NO content code.
  defp tenant, do: SharedInfra.Tenancy.default_app_id()

  defp mget(m, key), do: Map.get(m, key, Map.get(m, Atom.to_string(key)))

  defp limit(params) do
    case Integer.parse(to_string(params["limit"] || "")) do
      {n, _} when n > 0 and n <= @max_limit -> n
      _ -> @max_limit
    end
  end
end
