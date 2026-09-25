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

  Since 134 an unmatch FLAGS the row (`unmatched_at`) rather than deleting it, so the list shows
  active AND unmatched pairs, each with when it ended. See `UserService.DatingAdmin`.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  plug ApiGatewayWeb.Plugs.RequirePermission, "users.sensitive.view"

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
      {:error, {:reason_invalid, why}} -> reason_invalid(conn, why)
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
      {:error, {:reason_invalid, why}} -> reason_invalid(conn, why)
    end
  end

  # THE REASON GATE. Refused BEFORE the read runs, so an unexplained request never touches the data
  # — the audit row and the query are not allowed to disagree about whether an access happened.
  # The rule itself lives in SharedInfra.ReasonPolicy and is mirrored by the console: 12+ characters,
  # two words, a vowel, and not the same characters over and over.
  defp reason(params) do
    case SharedInfra.ReasonPolicy.validate(params["reason"]) do
      {:ok, reason} -> {:ok, reason}
      {:error, :required} -> {:error, :reason_required}
      {:error, {:invalid, why}} -> {:error, {:reason_invalid, why}}
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

  defp forward(conn, {:ok, data}), do: json(conn, with_avatar_urls(data))

  defp forward(conn, _error),
    do: ErrorResponse.service_unavailable(conn, "admin.unavailable")

  # Both users' avatars, presigned the same way every profile card presigns one — purpose-asserted
  # so a poisoned avatar id cannot presign a message attachment — and CONCURRENTLY, because a page
  # of 100 rows is 200 media round-trips and doing them in series blocked the whole response. A
  # failed presign degrades that one photo to nothing; it never fails the page.
  @presign_concurrency 16
  @presign_timeout_ms 5_000
  defp with_avatar_urls(%{} = data) do
    matches = mget(data, :matches) || []
    app_id = SharedInfra.Tenancy.default_app_id()

    ids =
      matches
      |> Enum.flat_map(
        &[mget(&1, :user_low_avatar_media_id), mget(&1, :user_high_avatar_media_id)]
      )
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    urls = presigned_map(ids, app_id)

    enriched =
      Enum.map(matches, fn m ->
        m
        |> Map.put(:user_low_avatar_url, Map.get(urls, mget(m, :user_low_avatar_media_id)))
        |> Map.put(:user_high_avatar_url, Map.get(urls, mget(m, :user_high_avatar_media_id)))
      end)

    Map.put(data, :matches, enriched)
  rescue
    _ -> data
  end

  defp with_avatar_urls(data), do: data

  defp presigned_map(ids, app_id) do
    ids
    |> Task.async_stream(fn id -> {id, presign(id, app_id)} end,
      max_concurrency: @presign_concurrency,
      timeout: @presign_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, {id, url}} when is_binary(url) -> &Map.put(&1, id, url)
      _ -> & &1
    end)
  end

  defp presign(media_id, app_id) do
    case SharedInfra.MediaClient.get_download_url(%{
           "media_id" => media_id,
           "app_id" => app_id,
           "purpose" => "user_avatar"
         }) do
      {:ok, %{} = download} -> mget(download, :download_url)
      _ -> nil
    end
  end

  defp mget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp mget(_map, _key), do: nil

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

  # A reason was given and it is not one. Still 400, still not 403 — but with the rule it broke,
  # so the console can show it inline instead of "request invalid".
  defp reason_invalid(conn, why),
    do:
      ErrorResponse.invalid_request_with(
        conn,
        "admin.reason_invalid",
        "Reason not accepted: #{why}",
        %{rule: why}
      )
end
