defmodule ApiGatewayWeb.AdminModerationController do
  @moduledoc """
  Admin moderation endpoints — gated by `ApiGatewayWeb.Plugs.RequireAdmin` (the admin session is in
  `conn.assigns.admin_session`). User suspend/reactivate/ban and report actions are proxied to
  auth-service (which mutates + writes its own audit row). Admin message-delete is proxied to
  message-service, then this controller records the audit row via the auth client (one place owns
  audit). Every mutation is attributed to the acting admin (`actor_user_id`).
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse
  alias ApiGatewayWeb.Plugs.RequirePermission

  # Per-route capability (IAM Phase 1). Viewing users/reports = users.view; any mutation
  # (suspend/reactivate/ban/message-delete/report-status) = users.moderate; the audit log = audit.view.
  plug RequirePermission, "users.view" when action in [:list_users, :get_user, :list_reports]

  plug RequirePermission,
       "users.moderate"
       when action in [
              :suspend_user,
              :reactivate_user,
              :ban_user,
              :revoke_sessions,
              :delete_message,
              :update_report
            ]

  plug RequirePermission, "audit.view" when action in [:list_audit]

  # Role assignment + permanent delete are root-only (roles.manage / users.delete are in root's bundle only).
  plug RequirePermission, "roles.manage" when action in [:set_user_role]
  plug RequirePermission, "users.delete" when action in [:delete_user]

  # STEP-UP (132): ban and permanent delete always. A role change is gated INSIDE the action, because
  # "to or from root/admin" needs the target's CURRENT role, which a plug cannot see. Ordered after
  # RequirePermission on purpose — you must be allowed to do the thing before being asked to prove
  # it is really you; the other order would tell a moderator to step up for something root-only.
  plug ApiGatewayWeb.Plugs.RequireReauth when action in [:ban_user, :delete_user]

  # --- Users ----------------------------------------------------------------------------------
  def list_users(conn, params) do
    forward(conn, SharedInfra.AuthClient.list_users(scoped(take_paging(params))))
  end

  # THE ONE AUDITED READ. Opening a person's record — phone, email, enforcement history, reports — is
  # the read worth recording; list/search pages are not (they are how you navigate, and auditing every
  # keystroke would bury the reads that matter). Best-effort: the audit never blocks the view.
  def get_user(conn, %{"id" => user_id}) do
    result = SharedInfra.AuthClient.get_user_detail(scoped(%{"user_id" => user_id}))

    if match?({:ok, _}, result) do
      SharedInfra.AuthClient.write_audit(
        Map.merge(ApiGatewayWeb.RequestContext.audit_attrs(conn), %{
          "actor_user_id" => actor(conn),
          "action" => "user.view",
          "target_type" => "user",
          "target_id" => user_id,
          "metadata" => %{}
        })
      )
    end

    forward(conn, result)
  end

  def suspend_user(conn, %{"id" => user_id} = params) do
    forward(
      conn,
      SharedInfra.AuthClient.suspend_user(
        scoped(conn, %{
          "user_id" => user_id,
          "reason" => params["reason"],
          "ends_at" => params["ends_at"],
          "actor_user_id" => actor(conn)
        })
      )
    )
  end

  def reactivate_user(conn, %{"id" => user_id}) do
    forward(
      conn,
      SharedInfra.AuthClient.reactivate_user(
        scoped(conn, %{"user_id" => user_id, "actor_user_id" => actor(conn)})
      )
    )
  end

  def ban_user(conn, %{"id" => user_id} = params) do
    forward(
      conn,
      SharedInfra.AuthClient.ban_user(
        scoped(conn, %{
          "user_id" => user_id,
          "reason" => params["reason"],
          "actor_user_id" => actor(conn)
        })
      )
    )
  end

  @doc """
  POST /api/v1/admin/users/:id/revoke-sessions — sign this account out everywhere.

  Reuses the SAME transaction a user-driven revoke uses, so the refresh tokens and push tokens go
  with the sessions: an account that is "signed out" but still receiving pushes is not signed out.
  Then it does what the device endpoint does for one device, for every device — tells the clients
  they were signed out BEFORE severing the socket, so an open tab can render the reason instead of a
  silently dead connection, and notifies secret chats because the user's live key set just changed.

  Idempotent: an account with nothing live answers `revoked_count: 0` rather than an error — this is
  a button an operator may well press twice.
  """
  def revoke_sessions(conn, %{"id" => user_id}) do
    case SharedInfra.AuthClient.revoke_all_sessions(%{"user_id" => user_id}) do
      {:ok, result} ->
        device_ids = cget(result, :revoked_device_ids) || []

        ApiGatewayWeb.SecretChatEvents.emit_keys_changed(user_id)

        Enum.each(device_ids, fn device_id ->
          ApiGatewayWeb.Endpoint.broadcast("user:" <> user_id, "session_revoked", %{
            device_id: device_id,
            session_id: nil
          })

          ApiGatewayWeb.Endpoint.broadcast(
            "user_socket:#{user_id}:#{device_id}",
            "disconnect",
            %{}
          )
        end)

        SharedInfra.AuthClient.write_audit(
          Map.merge(ApiGatewayWeb.RequestContext.audit_attrs(conn), %{
            "actor_user_id" => actor(conn),
            "action" => "user.revoke_sessions",
            "target_type" => "user",
            "target_id" => user_id,
            "metadata" => %{"revoked_count" => cget(result, :revoked_count) || 0}
          })
        )

        json(conn, %{
          user_id: user_id,
          revoked: true,
          revoked_count: cget(result, :revoked_count) || 0
        })

      {:error, reason} ->
        error(conn, reason)
    end
  end

  def revoke_sessions(conn, _params),
    do: ErrorResponse.invalid_request(conn, "admin.invalid_request")

  # --- Messages -------------------------------------------------------------------------------
  # Tenant gate (message_service admin_delete has no app_id): resolve the message's conversation tenant;
  # a conversation outside the console's tenant → 404, no delete (same predicate the content viewer uses).
  def delete_message(conn, %{"id" => message_id} = params) do
    with :ok <- ensure_tenant_conversation(params["conversation_id"]),
         {:ok, data} <-
           SharedInfra.MessageClient.admin_delete_message(%{
             "message_id" => message_id,
             "conversation_id" => params["conversation_id"]
           }) do
      # Best-effort audit (the delete already happened); record who removed what.
      SharedInfra.AuthClient.write_audit(
        Map.merge(ApiGatewayWeb.RequestContext.audit_attrs(conn), %{
          "actor_user_id" => actor(conn),
          "action" => "message.delete",
          "target_type" => "message",
          "target_id" => message_id,
          "metadata" => %{"conversation_id" => params["conversation_id"]}
        })
      )

      json(conn, data)
    else
      {:error, :not_found} -> ErrorResponse.not_found(conn, "admin.not_found", "Not found")
      {:error, reason} -> error(conn, reason)
    end
  end

  # --- Reports --------------------------------------------------------------------------------
  def list_reports(conn, params) do
    result =
      enrich_rows(SharedInfra.AuthClient.list_reports(scoped(take_paging(params))), :reports, %{
        reporter_user_id: :reporter,
        reported_user_id: :reported
      })

    forward(conn, result)
  end

  def update_report(conn, %{"id" => report_id} = params) do
    forward(
      conn,
      SharedInfra.AuthClient.update_report(
        scoped(conn, %{
          "report_id" => report_id,
          "status" => params["status"],
          "resolution" => params["resolution"],
          "actor_user_id" => actor(conn)
        })
      )
    )
  end

  # --- Roles (IAM Phase 1) --------------------------------------------------------------------
  def set_user_role(conn, %{"id" => user_id} = params) do
    with :ok <- ensure_reauth_for_role_change(conn, user_id, params["role"]) do
      forward(
        conn,
        SharedInfra.AuthClient.set_user_role(
          scoped(conn, %{
            "user_id" => user_id,
            "role" => params["role"],
            "actor_user_id" => actor(conn)
          })
        )
      )
    else
      {:error, :reauth_required} ->
        ErrorResponse.forbidden(
          conn,
          "admin.reauth_required",
          "Confirm it's you: re-enter the code sent to your phone"
        )
    end
  end

  # Permanent delete (root-only via RequirePermission users.delete). Guards + transaction live in auth.
  def delete_user(conn, %{"id" => user_id}) do
    forward(
      conn,
      SharedInfra.AuthClient.delete_user(
        scoped(conn, %{"user_id" => user_id, "actor_user_id" => actor(conn)})
      )
    )
  end

  # --- Audit ----------------------------------------------------------------------------------
  def list_audit(conn, params) do
    result =
      enrich_rows(SharedInfra.AuthClient.list_audit(take_paging(params)), :entries, %{
        actor_user_id: :actor
      })

    forward(conn, result)
  end

  # Resolve the raw user-id fields in a list response to display_name + phone (ONE batched auth lookup —
  # no N+1) so the admin panel shows WHO, not a hash. `id_fields` maps an id field → a name prefix, so
  # e.g. reporter_user_id → reporter_name / reporter_phone. Best-effort: any failure returns the response
  # unchanged (ids only).
  defp enrich_rows({:ok, %{} = data}, list_key, id_fields) do
    rows = mfetch(data, list_key) || []

    ids =
      for row <- rows,
          {id_field, _prefix} <- id_fields,
          v = mfetch(row, id_field),
          is_binary(v),
          do: v

    lookup =
      case SharedInfra.AuthClient.list_user_summaries(%{"user_ids" => Enum.uniq(ids)}) do
        {:ok, res} ->
          (mfetch(res, :summaries) || []) |> Map.new(fn s -> {mfetch(s, :user_id), s} end)

        _ ->
          %{}
      end

    enriched =
      Enum.map(rows, fn row ->
        Enum.reduce(id_fields, row, fn {id_field, prefix}, acc ->
          case Map.get(lookup, mfetch(row, id_field)) do
            nil ->
              acc

            s ->
              acc
              |> Map.put(:"#{prefix}_name", mfetch(s, :display_name))
              |> Map.put(:"#{prefix}_phone", mfetch(s, :phone_number))
          end
        end)
      end)

    {:ok, Map.put(data, list_key, enriched)}
  rescue
    _ -> {:ok, data}
  end

  defp enrich_rows(other, _list_key, _id_fields), do: other

  defp mfetch(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp mfetch(_map, _key), do: nil

  # --- helpers --------------------------------------------------------------------------------
  defp forward(conn, {:ok, data}), do: json(conn, data)
  defp forward(conn, {:error, reason}), do: error(conn, reason)

  defp error(conn, :auth_unavailable),
    do: ErrorResponse.service_unavailable(conn, "admin.unavailable")

  defp error(conn, :message_unavailable),
    do: ErrorResponse.service_unavailable(conn, "admin.unavailable")

  defp error(conn, :user_not_found),
    do: ErrorResponse.invalid_request(conn, "admin.user_not_found")

  # IAM role-assignment errors: the last root can't be demoted; unknown role value.
  defp error(conn, :last_root),
    do: ErrorResponse.invalid_request(conn, "iam.last_root")

  defp error(conn, :invalid_role),
    do: ErrorResponse.invalid_request(conn, "iam.invalid_role")

  defp error(conn, :cannot_delete_privileged),
    do: ErrorResponse.invalid_request(conn, "iam.cannot_delete_privileged")

  defp error(conn, :cannot_delete_self),
    do: ErrorResponse.invalid_request(conn, "iam.cannot_delete_self")

  # Moderation hierarchy guard → 403 (you may only act on a strictly lower-ranked target, never yourself).
  defp error(conn, :cannot_moderate_peer_or_superior),
    do:
      ErrorResponse.forbidden(
        conn,
        "iam.cannot_moderate_peer_or_superior",
        "You can only moderate users below your role"
      )

  defp error(conn, :cannot_moderate_self),
    do: ErrorResponse.forbidden(conn, "iam.cannot_moderate_self", "You cannot moderate yourself")

  defp error(conn, :report_not_found),
    do: ErrorResponse.invalid_request(conn, "admin.report_not_found")

  defp error(conn, _reason), do: ErrorResponse.invalid_request(conn, "admin.invalid_request")

  # STEP-UP for a role change, gated on the PRIVILEGED SET on either side (132). A plug cannot decide
  # this: "to root/admin" is in the request, but "FROM root/admin" — demoting a root, the move that
  # actually removes someone's power — is only knowable by reading the target's current role. So the
  # check happens here, after the permission plug, with one lookup.
  #
  # Unreadable current role → treated as privileged, i.e. step up anyway. A lookup failure must not
  # be the thing that lets a role change through unproven.
  @privileged_roles ~w(root admin)

  defp ensure_reauth_for_role_change(conn, user_id, new_role) do
    if new_role in @privileged_roles or current_role_privileged?(user_id) do
      case SharedInfra.AuthClient.admin_reauth_check(%{
             "token" => ApiGatewayWeb.Plugs.RequireReauth.reauth_token(conn),
             "user_id" => actor(conn)
           }) do
        {:ok, _} -> :ok
        _ -> {:error, :reauth_required}
      end
    else
      :ok
    end
  end

  defp current_role_privileged?(user_id) do
    case SharedInfra.AuthClient.get_user_detail(scoped(%{"user_id" => user_id})) do
      {:ok, detail} ->
        auth = cget(detail, :auth) || %{}
        (cget(auth, :role) || "") in @privileged_roles or cget(auth, :is_admin) == true

      _ ->
        true
    end
  end

  defp actor(conn), do: conn.assigns.admin_session.user_id

  # Internal results come atom-keyed in-process and string-keyed over HTTP — read either.
  defp cget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp cget(_map, _key), do: nil

  defp take_paging(params), do: Map.take(params, ["page", "status", "q"])

  # The admin console is the FIRST-PARTY product only → every user/report query is confined to tenant-zero
  # (SharedInfra.Tenancy.default_app_id/0, the single source). A cross-tenant id then resolves to nothing →
  # 404, no side effect. A cross-tenant *operations* view is a separate future route with its own controller.
  defp scoped(attrs), do: Map.put(attrs, "app_id", SharedInfra.Tenancy.default_app_id())

  # Tenant AND the request facts, in one call, so a mutation physically cannot be written without the
  # context its audit row needs (audit_logs.ip_address / user_agent were NULL on every row until now).
  defp scoped(conn, attrs),
    do: attrs |> scoped() |> Map.merge(ApiGatewayWeb.RequestContext.audit_attrs(conn))

  # The message's conversation must belong to the console's tenant. Missing / cross-tenant / unresolvable
  # → :not_found (404). messages.app_id is unreliable, so the tenant comes from the parent conversation.
  defp ensure_tenant_conversation(conversation_id)
       when is_binary(conversation_id) and conversation_id != "" do
    case SharedInfra.ConversationClient.get_conversation_app(%{
           "conversation_id" => conversation_id
         }) do
      {:ok, %{app_id: app_id}} ->
        if app_id == SharedInfra.Tenancy.default_app_id(), do: :ok, else: {:error, :not_found}

      {:ok, map} when is_map(map) ->
        if Map.get(map, "app_id") == SharedInfra.Tenancy.default_app_id(),
          do: :ok,
          else: {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  end

  defp ensure_tenant_conversation(_), do: {:error, :not_found}
end
