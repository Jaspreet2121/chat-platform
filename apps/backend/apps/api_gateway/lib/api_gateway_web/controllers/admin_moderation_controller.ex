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

  # --- Users ----------------------------------------------------------------------------------
  def list_users(conn, params) do
    forward(conn, SharedInfra.AuthClient.list_users(take_paging(params)))
  end

  def suspend_user(conn, %{"id" => user_id} = params) do
    forward(
      conn,
      SharedInfra.AuthClient.suspend_user(%{
        "user_id" => user_id,
        "reason" => params["reason"],
        "ends_at" => params["ends_at"],
        "actor_user_id" => actor(conn)
      })
    )
  end

  def reactivate_user(conn, %{"id" => user_id}) do
    forward(
      conn,
      SharedInfra.AuthClient.reactivate_user(%{
        "user_id" => user_id,
        "actor_user_id" => actor(conn)
      })
    )
  end

  def ban_user(conn, %{"id" => user_id} = params) do
    forward(
      conn,
      SharedInfra.AuthClient.ban_user(%{
        "user_id" => user_id,
        "reason" => params["reason"],
        "actor_user_id" => actor(conn)
      })
    )
  end

  # --- Messages -------------------------------------------------------------------------------
  def delete_message(conn, %{"id" => message_id} = params) do
    case SharedInfra.MessageClient.admin_delete_message(%{
           "message_id" => message_id,
           "conversation_id" => params["conversation_id"]
         }) do
      {:ok, data} ->
        # Best-effort audit (the delete already happened); record who removed what.
        SharedInfra.AuthClient.write_audit(%{
          "actor_user_id" => actor(conn),
          "action" => "message.delete",
          "target_type" => "message",
          "target_id" => message_id,
          "metadata" => %{"conversation_id" => params["conversation_id"]}
        })

        json(conn, data)

      {:error, reason} ->
        error(conn, reason)
    end
  end

  # --- Reports --------------------------------------------------------------------------------
  def list_reports(conn, params) do
    forward(conn, SharedInfra.AuthClient.list_reports(take_paging(params)))
  end

  def update_report(conn, %{"id" => report_id} = params) do
    forward(
      conn,
      SharedInfra.AuthClient.update_report(%{
        "report_id" => report_id,
        "status" => params["status"],
        "resolution" => params["resolution"],
        "actor_user_id" => actor(conn)
      })
    )
  end

  # --- Audit ----------------------------------------------------------------------------------
  def list_audit(conn, params) do
    forward(conn, SharedInfra.AuthClient.list_audit(take_paging(params)))
  end

  # --- helpers --------------------------------------------------------------------------------
  defp forward(conn, {:ok, data}), do: json(conn, data)
  defp forward(conn, {:error, reason}), do: error(conn, reason)

  defp error(conn, :auth_unavailable),
    do: ErrorResponse.service_unavailable(conn, "admin.unavailable")

  defp error(conn, :message_unavailable),
    do: ErrorResponse.service_unavailable(conn, "admin.unavailable")

  defp error(conn, :user_not_found),
    do: ErrorResponse.invalid_request(conn, "admin.user_not_found")

  defp error(conn, :report_not_found),
    do: ErrorResponse.invalid_request(conn, "admin.report_not_found")

  defp error(conn, _reason), do: ErrorResponse.invalid_request(conn, "admin.invalid_request")

  defp actor(conn), do: conn.assigns.admin_session.user_id

  defp take_paging(params), do: Map.take(params, ["page", "status", "q"])
end
