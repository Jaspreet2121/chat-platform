defmodule ApiGatewayWeb.InviteLinkController do

  # JOIN LIMITS — two axes, and both are needed because they stop different attacks.
  #
  # PER USER (10/hour): stops one account joining every link it can find.
  # PER CODE (60/hour): stops MANY accounts draining ONE leaked link. A per-user limit is blind to
  # that: 500 accounts each making one join are all within their own budget, and the group is flooded
  # anyway. This is the first per-RESOURCE limit in the codebase — see SharedInfra.ResourceLimit for
  # the key shape.
  #
  # AT THE CAP THE LINK STAYS ALIVE and the joiner gets a 429; the window drains on its own. The
  # tempting alternative — put the link dormant until the owner resets it — was rejected: it hands
  # anyone who can see a link the power to permanently disable it, which turns this limiter into a
  # griefing tool aimed at the owner. Self-healing is the weaker-looking option that cannot be
  # weaponised, and the owner keeps `reset_link` as the escalation when a code has genuinely leaked.
  #
  # 60/hour is deliberately generous: a legitimately viral group and an attack look IDENTICAL from
  # here, so the number is set where a real group is unlikely to notice (a 100-person onboarding
  # takes two hours, with an honest Retry-After) while 500 scripted accounts need 8+ hours — long
  # enough for an owner to see it and rotate the code.
  @join_user_limit 10
  @join_user_window_seconds 3600
  @join_code_limit 60
  @join_code_window_seconds 3600

  @moduledoc """
  Group invite links (077) — REST for the shareable, WhatsApp-style "join a group via link". Session-gated
  (first-party). Management (create / revoke / reset) is conversation-scoped and OWNER-ONLY; preview + join
  are code-scoped.

    POST   /api/v1/conversations/:conversation_id/invite-link        → { code, url }  (mint or existing)
    DELETE /api/v1/conversations/:conversation_id/invite-link        → { revoked: true }
    POST   /api/v1/conversations/:conversation_id/invite-link/reset   → { code, url }  (revoke + mint)
    GET    /api/v1/invite-links/:code                                 → { name, avatar_url, member_count }
    POST   /api/v1/invite-links/:code/join                            → { status, conversation_id, role }

  A join goes through the SAME participant path as an owner add — after a fresh join we fire the identical
  `conversation_updated` `:participant` frame, so the joiner's inbox row / unread / fan-out match exactly.
  Unknown / revoked code → 404 (never reveals a code once existed); non-owner → 403 conversation.not_owner;
  a REMOVED user rejoining → 403 invite_link.removed.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  # POST /conversations/:conversation_id/invite-link
  def create_link(conn, %{"conversation_id" => conversation_id}) do
    with {:ok, session} <- current_session(conn),
         {:ok, result} <-
           SharedInfra.ConversationClient.create_group_invite_link(%{
             "conversation_id" => conversation_id,
             "actor_user_id" => session.user_id
           }) do
      json(conn, link_payload(result))
    else
      error -> handle_error(conn, error)
    end
  end

  # DELETE /conversations/:conversation_id/invite-link
  def revoke_link(conn, %{"conversation_id" => conversation_id}) do
    with {:ok, session} <- current_session(conn),
         {:ok, _result} <-
           SharedInfra.ConversationClient.revoke_group_invite_link(%{
             "conversation_id" => conversation_id,
             "actor_user_id" => session.user_id
           }) do
      json(conn, %{revoked: true})
    else
      error -> handle_error(conn, error)
    end
  end

  # POST /conversations/:conversation_id/invite-link/reset
  def reset_link(conn, %{"conversation_id" => conversation_id}) do
    with {:ok, session} <- current_session(conn),
         {:ok, result} <-
           SharedInfra.ConversationClient.reset_group_invite_link(%{
             "conversation_id" => conversation_id,
             "actor_user_id" => session.user_id
           }) do
      json(conn, link_payload(result))
    else
      error -> handle_error(conn, error)
    end
  end

  # GET /invite-links/:code — the join preview (session-gated, exactly {name, avatar_url, member_count}).
  def preview(conn, %{"code" => code}) when is_binary(code) and code != "" do
    with {:ok, session} <- current_session(conn),
         {:ok, result} <-
           SharedInfra.ConversationClient.preview_group_invite_link(%{
             "code" => code,
             "app_id" => session_app(session)
           }) do
      json(conn, %{
        name: cget(result, :name),
        avatar_url:
          preview_avatar_url(cget(result, :group_avatar_media_id), session_app(session)),
        member_count: cget(result, :member_count)
      })
    else
      error -> handle_error(conn, error)
    end
  end

  def preview(conn, _params),
    do: ErrorResponse.invalid_request(conn, "invite_link.invalid_request")

  # POST /invite-links/:code/join
  def join(conn, %{"code" => code}) when is_binary(code) and code != "" do
    with {:ok, session} <- current_session(conn),
         # Per-ACTOR first: it is the cheaper signal, and it bounds how much of the code's budget any
         # one caller can burn. That matters because the code is charged before we know the outcome —
         # an already-member re-join still spends from the pot (see join_code_limit/1).
         :ok <- join_user_limit(session.user_id),
         :ok <- join_code_limit(code),
         {:ok, result} <-
           SharedInfra.ConversationClient.join_group_invite_link(%{
             "code" => code,
             "user_id" => session.user_id,
             "app_id" => session_app(session)
           }) do
      status = cget(result, :status)
      conversation_id = cget(result, :conversation_id)

      # A FRESH join changed the participant set → fire the SAME :participant frame an owner add fires (fans
      # to every member INCLUDING the joiner, which is how the group appears in their inbox live). An
      # already-member join changed nothing → stay silent.
      if status == "joined" do
        ApiGatewayWeb.ConversationBroadcast.broadcast_updated(
          conversation_id,
          session.user_id,
          :participant
        )
      end

      json(conn, %{status: status, conversation_id: conversation_id, role: cget(result, :role)})
    else
      error -> handle_error(conn, error)
    end
  end

  def join(conn, _params), do: ErrorResponse.invalid_request(conn, "invite_link.invalid_request")

  # --- limits ------------------------------------------------------------------------------------

  # Both FAIL-CLOSED: on this endpoint the limiter IS the security control, so a limiter outage must
  # not reopen the mass-join path. The cost of failing closed is small and recoverable — joining a
  # group is not time-critical, and a refused joiner can simply try again — which is exactly the
  # trade that made message send fail OPEN and this one fail CLOSED.
  defp join_user_limit(user_id) do
    case SharedInfra.RateLimiter.check_rate(%{
           "key" => "invite_join:" <> user_id,
           "limit" => @join_user_limit,
           "window_seconds" => @join_user_window_seconds,
           "fail_open" => false
         }) do
      :ok -> :ok
      {:error, :rate_limited, _retry} = limited -> limited
      _ -> {:error, :rate_limiter_unavailable}
    end
  end

  # Charged BEFORE the join resolves, which is what lets it REFUSE the (N+1)th join rather than
  # noticing afterwards. The accepted residual: a caller who turns out to be an existing member, or
  # who is refused for having been removed, still spends a unit of the code's budget. Bounded by the
  # per-user limit above (10/hour each), and the owner's remedy is reset_link. Charging only on a
  # successful seat would need a peek-then-commit the INCR-based limiter does not offer.
  defp join_code_limit(code) do
    SharedInfra.ResourceLimit.check("invite_code", code, "join",
      limit: @join_code_limit,
      window_seconds: @join_code_window_seconds,
      fail_open: false
    )
  end

  # --- helpers -----------------------------------------------------------------------------------

  defp link_payload(result) do
    code = cget(result, :code)
    %{code: code, url: invite_url(code)}
  end

  # The shareable link: WEB_BASE_URL (default https://web.growblic.com) + /join/<code>. Distinct from the
  # phone-invite path (/invite/<code>) so the two features never collide.
  defp invite_url(code) do
    base =
      Application.get_env(:api_gateway, :web_base_url) || System.get_env("WEB_BASE_URL") ||
        "https://web.growblic.com"

    String.trim_trailing(base, "/") <> "/join/" <> code
  end

  # Presign the group avatar for the preview (same purpose assertion as the conversation list/detail). A
  # missing avatar or media error → nil (client falls back to initials). Non-security best-effort.
  defp preview_avatar_url(media_id, app_id) when is_binary(media_id) and is_binary(app_id) do
    case SharedInfra.MediaClient.get_download_url(%{
           "media_id" => media_id,
           "app_id" => app_id,
           "purpose" => "group_avatar"
         }) do
      {:ok, download} -> Map.get(download, :download_url) || Map.get(download, "download_url")
      _ -> nil
    end
  end

  defp preview_avatar_url(_media_id, _app_id), do: nil

  defp current_session(conn) do
    with {:ok, authorization} <- authorization_header(conn) do
      SharedInfra.AuthClient.current_session(%{"authorization" => authorization})
    end
  end

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token = authorization] when token != "" -> {:ok, authorization}
      _ -> {:error, :session_invalid}
    end
  end

  defp session_app(session), do: Map.get(session, :app_id)

  defp handle_error(conn, {:error, :session_invalid}),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Invalid or missing session")

  defp handle_error(conn, {:error, :rate_limited, retry_after_seconds}),
    do:
      conn
      |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
      |> ErrorResponse.rate_limited("invite_link.rate_limited")

  defp handle_error(conn, {:error, :rate_limiter_unavailable}),
    do:
      conn
      |> put_resp_header("retry-after", "30")
      |> ErrorResponse.service_unavailable("invite_link.limiter_unavailable")

  defp handle_error(conn, {:error, :not_owner}),
    do:
      ErrorResponse.forbidden(
        conn,
        "conversation.not_owner",
        "Only the group owner can manage the invite link"
      )

  defp handle_error(conn, {:error, :removed}),
    do:
      ErrorResponse.forbidden(
        conn,
        "invite_link.removed",
        "You were removed from this group and can't rejoin via link"
      )

  defp handle_error(conn, {:error, :link_not_found}),
    do: ErrorResponse.not_found(conn, "invite_link.not_found", "Invite link not found")

  # A non-group / unknown conversation for the management ops → 404 (nothing revealed about the id).
  defp handle_error(conn, {:error, reason})
       when reason in [:not_a_group, :conversation_not_found],
       do: ErrorResponse.not_found(conn, "conversation.not_found", "Not found")

  defp handle_error(conn, {:error, :conversation_unavailable}),
    do: ErrorResponse.service_unavailable(conn, "invite_link.unavailable")

  defp handle_error(conn, _other),
    do: ErrorResponse.invalid_request(conn, "invite_link.invalid_request")

  defp cget(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
