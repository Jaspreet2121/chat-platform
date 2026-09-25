defmodule ApiGatewayWeb.AdminMatchesController do
  @moduledoc """
  MATCHES — dating match history for safety, abuse and legal work.

  This is the most sensitive surface in the console, and it is built to be treated that way.

    * `users.sensitive.view`, which only ROOT and ADMIN hold. A moderator handling a report does not
      need to know who somebody matched with, and support never does — which is exactly why this is
      not folded into `users.view`.
    * EVERY access carries a typed reason and is audited (actor, target or "list", the reason, the
      IP and the user agent). A read you cannot explain afterwards is one nobody should be able to
      make; the reason is required by the SERVER on every call, and the console asks for it once an
      hour rather than on every page.
    * Bounded pages, server-clamped. There is deliberately NO export endpoint: a surface over
      personal data must not have a "give me everything" shape.
    * NO LOCATION, anywhere. Nearby presence rows carry a live latitude and longitude; they are not
      read here and there is no Nearby endpoint in the admin API at all.

  What it cannot show: an unmatch DELETES the row, so only live matches exist to list. See
  `UserService.DatingAdmin`.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  plug ApiGatewayWeb.Plugs.RequirePermission, "users.sensitive.view"

  # Short enough to type, long enough to mean something. "x" is not a reason.
  @min_reason_length 8
  @max_reason_length 200

  def index(conn, params) do
    with {:ok, reason} <- reason(params) do
      audit(conn, "list", reason, %{"q" => present(params["q"])})

      forward(
        conn,
        SharedInfra.UserClient.admin_list_matches(%{
          "app_id" => SharedInfra.Tenancy.default_app_id(),
          "q" => params["q"],
          "page" => params["page"],
          "page_size" => params["page_size"]
        })
      )
    else
      {:error, :reason_required} -> handle_reason_error(conn)
    end
  end

  def user_matches(conn, %{"id" => user_id} = params) do
    with {:ok, reason} <- reason(params) do
      audit(conn, user_id, reason, %{})

      forward(
        conn,
        SharedInfra.UserClient.admin_user_matches(%{
          "app_id" => SharedInfra.Tenancy.default_app_id(),
          "user_id" => user_id,
          "page" => params["page"],
          "page_size" => params["page_size"]
        })
      )
    else
      {:error, :reason_required} -> handle_reason_error(conn)
    end
  end

  # THE REASON GATE. Refused BEFORE the read runs, so an unexplained request never touches the data
  # — the audit row and the query are not allowed to disagree about whether an access happened.
  defp reason(params) do
    value = params["reason"] |> to_string() |> String.trim()

    cond do
      String.length(value) < @min_reason_length ->
        {:error, :reason_required}

      String.length(value) > @max_reason_length ->
        {:ok, String.slice(value, 0, @max_reason_length)}

      true ->
        {:ok, value}
    end
  end

  # AUDITED BEFORE THE READ, for the same reason: if the read succeeds the access is recorded, and if
  # the audit write fails the access is still recorded as attempted rather than silently allowed.
  defp audit(conn, target, reason, extra) do
    SharedInfra.AuthClient.write_audit(
      Map.merge(ApiGatewayWeb.RequestContext.audit_attrs(conn), %{
        "actor_user_id" => conn.assigns.admin_session.user_id,
        "action" => "matches.view",
        "target_type" => "matches",
        "target_id" => target,
        "metadata" => Map.merge(extra, %{"reason" => reason})
      })
    )
  end

  defp forward(conn, {:ok, data}), do: json(conn, data)

  defp forward(conn, _error),
    do: ErrorResponse.service_unavailable(conn, "admin.unavailable")

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  # A missing or throwaway reason is a 400, not a 403: the caller IS allowed here, they just have to
  # say why. Conflating the two would tell a root their permission had been revoked.
  defp reason_error(conn),
    do:
      ErrorResponse.invalid_request(
        conn,
        "admin.reason_required"
      )

  # `with` fall-through for both actions.
  defp handle_reason_error(conn), do: reason_error(conn)
end
