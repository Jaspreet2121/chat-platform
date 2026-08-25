defmodule ApiGatewayWeb.DatingController do
  @moduledoc """
  Dating (105) — session-owned, and deliberately NOT riding ProfilePresenter: dating has its own
  card (first name, computed age, dating photos, bio, rounded km — never coordinates), and dating
  data appears on no other surface. Store-level policy (enable gate, mutual filters, blocks,
  swipe/match semantics) lives in UserService.Dating; this controller adds presigned photo URLs,
  the match's conversation create-or-get (the EXACT nearby-accept path — one DM creation route in
  the whole product), and the realtime events.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  @deck_limit 12
  @swipe_limit 60
  @window_seconds 60
  @limiter_outage_retry 30

  # GET /api/v1/dating/profile
  def profile(conn, _params) do
    with {:ok, session} <- session(conn),
         {:ok, profile} <-
           SharedInfra.UserClient.get_dating_profile(%{"user_id" => session.user_id}) do
      json(conn, own_profile_view(profile))
    else
      error -> handle_error(conn, error)
    end
  end

  # PATCH /api/v1/dating/profile — partial; broadcasts dating_profile_changed to self.
  def update_profile(conn, params) do
    with {:ok, session} <- session(conn),
         {:ok, profile} <-
           SharedInfra.UserClient.update_dating_profile(%{
             "user_id" => session.user_id,
             "app_id" => session_app(session),
             "enabled" => Map.get(params, "enabled"),
             "dob" => Map.get(params, "dob"),
             "gender" => Map.get(params, "gender"),
             "interested_in" => Map.get(params, "interested_in"),
             "bio" => Map.get(params, "bio"),
             "photos" => Map.get(params, "photos"),
             "location" => Map.get(params, "location"),
             "prefs" => Map.get(params, "prefs")
           }) do
      ApiGatewayWeb.Endpoint.broadcast("user:" <> session.user_id, "dating_profile_changed", %{
        "type" => "dating_profile_changed"
      })

      json(conn, own_profile_view(profile))
    else
      error -> handle_error(conn, error)
    end
  end

  # GET /api/v1/dating/deck?limit=
  def deck(conn, params) do
    with {:ok, session} <- session(conn),
         :ok <- rate_limit("dating_deck", session.user_id, @deck_limit),
         {:ok, result} <-
           SharedInfra.UserClient.dating_deck(%{
             "user_id" => session.user_id,
             "app_id" => session_app(session),
             "limit" => int_param(params, "limit")
           }) do
      json(conn, %{cards: present_cards(mget(result, :cards) || [], session)})
    else
      error -> handle_error(conn, error)
    end
  end

  # POST /api/v1/dating/swipes {"target_id","action"}
  def swipe(conn, %{"target_id" => target, "action" => action})
      when is_binary(target) and target != "" and action in ["like", "pass"] do
    with {:ok, session} <- session(conn),
         :ok <- rate_limit("dating_swipe", session.user_id, @swipe_limit),
         :ok <- not_blocked(session.user_id, target),
         {:ok, result} <-
           SharedInfra.UserClient.dating_swipe(%{
             "user_id" => session.user_id,
             "app_id" => session_app(session),
             "target_id" => target,
             "action" => action
           }) do
      if mget(result, :matched) == true do
        respond_matched(conn, session, target, result)
      else
        if action == "like" do
          # No ids beyond the type — the target fetches their likes list themselves.
          ApiGatewayWeb.Endpoint.broadcast("user:" <> target, "dating_like_received", %{
            "type" => "dating_like_received"
          })
        end

        json(conn, %{matched: false})
      end
    else
      error -> handle_error(conn, error)
    end
  end

  def swipe(conn, _params), do: ErrorResponse.invalid_request(conn, "dating.invalid")

  # GET /api/v1/dating/likes?cursor=
  def likes(conn, params) do
    with {:ok, session} <- session(conn),
         {:ok, result} <-
           SharedInfra.UserClient.dating_likes(%{
             "user_id" => session.user_id,
             "app_id" => session_app(session),
             "cursor" => Map.get(params, "cursor")
           }) do
      json(conn, %{
        cards: present_cards(mget(result, :cards) || [], session),
        next_cursor: mget(result, :next_cursor)
      })
    else
      error -> handle_error(conn, error)
    end
  end

  # GET /api/v1/dating/matches?cursor=
  def matches(conn, params) do
    with {:ok, session} <- session(conn),
         {:ok, result} <-
           SharedInfra.UserClient.dating_matches(%{
             "user_id" => session.user_id,
             "app_id" => session_app(session),
             "cursor" => Map.get(params, "cursor")
           }) do
      json(conn, %{
        matches: present_cards(mget(result, :matches) || [], session),
        next_cursor: mget(result, :next_cursor)
      })
    else
      error -> handle_error(conn, error)
    end
  end

  # DELETE /api/v1/dating/matches/:match_id — unmatch. Match row removed, swipes reset; the
  # CONVERSATION IS KEPT (recorded decision: deleting chats is destructive — the pair own their
  # history and can delete the chat themselves).
  def unmatch(conn, %{"match_id" => match_id}) when is_binary(match_id) and match_id != "" do
    with {:ok, session} <- session(conn),
         {:ok, result} <-
           SharedInfra.UserClient.dating_unmatch(%{
             "user_id" => session.user_id,
             "app_id" => session_app(session),
             "match_id" => match_id
           }) do
      peer = mget(result, :peer_user_id)

      for user <- [session.user_id, peer], is_binary(user) do
        ApiGatewayWeb.Endpoint.broadcast("user:" <> user, "dating_unmatched", %{
          "type" => "dating_unmatched",
          "match_id" => match_id
        })
      end

      json(conn, %{unmatched: true})
    else
      error -> handle_error(conn, error)
    end
  end

  def unmatch(conn, _params), do: ErrorResponse.invalid_request(conn, "dating.invalid")

  @doc false
  # BLOCK HOOK — the block controller calls this after a successful block: a blocked pair must not
  # stay matched. Best-effort BY CONSTRUCTION (rescue-all): the block already committed, and a
  # dating hiccup — or a test stub without this seam — must never turn a successful block into an
  # error. Store-level blocked exclusion on every dating read is the belt behind this braces.
  def unmatch_on_block(blocker_id, blocked_id, app_id) do
    do_unmatch_on_block(blocker_id, blocked_id, app_id)
  rescue
    error ->
      require Logger
      Logger.warning("dating unmatch-on-block skipped: #{inspect(error)}")
      :ok
  end

  defp do_unmatch_on_block(blocker_id, blocked_id, app_id) do
    case SharedInfra.UserClient.dating_unmatch_pair(%{
           "user_id" => blocker_id,
           "app_id" => app_id,
           "peer_user_id" => blocked_id
         }) do
      {:ok, result} ->
        if mget(result, :unmatched) == true do
          match_id = mget(result, :match_id)

          for user <- [blocker_id, blocked_id] do
            ApiGatewayWeb.Endpoint.broadcast("user:" <> user, "dating_unmatched", %{
              "type" => "dating_unmatched",
              "match_id" => match_id
            })
          end
        end

        :ok

      _ ->
        :ok
    end
  end

  # ---- match orchestration ----------------------------------------------------------------------

  # The match committed in the store; create-or-get the 1:1 through the ONE existing direct path
  # (nearby-accept precedent: idempotent find-or-create, never a second creation route), attach the
  # id to the match, broadcast dating_matched to BOTH. A conversation-service hiccup returns the
  # match without an id — attach self-heals on a later create because find-or-create is stable.
  defp respond_matched(conn, session, target, result) do
    match_id = mget(result, :match_id)

    conversation_id =
      mget(result, :conversation_id) || create_and_attach(session, target, match_id)

    for {user, peer} <- [{session.user_id, target}, {target, session.user_id}] do
      ApiGatewayWeb.Endpoint.broadcast("user:" <> user, "dating_matched", %{
        "type" => "dating_matched",
        "match_id" => match_id,
        "user_id" => peer,
        "conversation_id" => conversation_id
      })
    end

    json(conn, %{matched: true, match_id: match_id, conversation_id: conversation_id})
  end

  defp create_and_attach(session, target, match_id) do
    with {:ok, conversation} <-
           SharedInfra.ConversationClient.create_conversation(%{
             "type" => "direct",
             "created_by" => session.user_id,
             "participant_user_ids" => [target],
             "app_id" => session_app(session)
           }),
         conversation_id when is_binary(conversation_id) <-
           mget(conversation, :conversation_id) || mget(conversation, :id) do
      ApiGatewayWeb.ConversationBroadcast.broadcast_created(conversation)

      SharedInfra.UserClient.dating_attach_conversation(%{
        "match_id" => match_id,
        "conversation_id" => conversation_id
      })

      conversation_id
    else
      _ -> nil
    end
  end

  # ---- card presentation --------------------------------------------------------------------------

  # The dating card — its OWN presentation (never ProfilePresenter): photo media ids become
  # presigned URLs scoped to the caller's app; everything else passes through from the store,
  # which never emits coordinates.
  defp present_cards(cards, session) do
    app_id = session_app(session)

    Enum.map(cards, fn card ->
      photos =
        (mget(card, :photos) || [])
        |> Enum.map(&photo_url(&1, app_id))
        |> Enum.reject(&is_nil/1)

      card |> Map.new() |> Map.put(:photos, photos)
    end)
  end

  defp photo_url(media_id, app_id) do
    case SharedInfra.MediaClient.get_download_url(%{"media_id" => media_id, "app_id" => app_id}) do
      {:ok, download} -> mget(download, :download_url)
      _ -> nil
    end
  end

  # ---- plumbing -----------------------------------------------------------------------------------

  defp not_blocked(viewer, target) do
    case SharedInfra.ConversationClient.either_blocked?(%{"user_a" => viewer, "user_b" => target}) do
      {:ok, result} ->
        if mget(result, :blocked) == true, do: {:error, :dating_blocked}, else: :ok

      _ ->
        {:error, :dating_blocked}
    end
  end

  defp session(conn) do
    with ["Bearer " <> token] when token != "" <- get_req_header(conn, "authorization"),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => "Bearer " <> token}) do
      {:ok, session}
    else
      _ -> {:error, :session_invalid}
    end
  end

  defp rate_limit(kind, user_id, limit) do
    case SharedInfra.RateLimiter.check_rate(%{
           "key" => kind <> ":" <> user_id,
           "limit" => limit,
           "window_seconds" => @window_seconds,
           "fail_open" => false
         }) do
      :ok -> :ok
      {:error, :rate_limited, _retry} = limited -> limited
      _ -> {:error, :rate_limiter_unavailable}
    end
  end

  defp own_profile_view(profile) do
    %{
      enabled: bool_of(profile, :enabled, false),
      dob: mget(profile, :dob),
      age: mget(profile, :age),
      gender: mget(profile, :gender),
      interested_in: mget(profile, :interested_in) || [],
      bio: mget(profile, :bio),
      photos: mget(profile, :photos) || [],
      location: %{
        lat: mget(profile, :latitude),
        lng: mget(profile, :longitude),
        name: mget(profile, :location_name)
      },
      prefs: %{
        min_age: mget(profile, :min_age),
        max_age: mget(profile, :max_age),
        max_distance_km: mget(profile, :max_distance_km),
        genders: mget(profile, :pref_genders) || []
      }
    }
  end

  # Booleans read explicitly — never through mget (the falsy-mget trap).
  defp bool_of(map, key, default) do
    case {Map.get(map, key), Map.get(map, Atom.to_string(key))} do
      {value, _} when is_boolean(value) -> value
      {_, value} when is_boolean(value) -> value
      _ -> default
    end
  end

  defp int_param(params, key) do
    case Map.get(params, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {number, ""} -> number
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp handle_error(conn, {:error, :session_invalid}),
    do: ErrorResponse.unauthorized(conn, "auth.session_invalid", "Invalid or expired session")

  defp handle_error(conn, {:error, :rate_limited, retry}) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry))
    |> ErrorResponse.rate_limited("dating.rate_limited")
  end

  defp handle_error(conn, {:error, :rate_limiter_unavailable}) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(@limiter_outage_retry))
    |> ErrorResponse.service_unavailable("dating.unavailable")
  end

  defp handle_error(conn, {:error, :user_unavailable}),
    do: ErrorResponse.service_unavailable(conn, "dating.unavailable")

  defp handle_error(conn, {:error, :dating_underage}),
    do: ErrorResponse.forbidden(conn, "dating.underage", "You must be 18 or older to use Dating")

  defp handle_error(conn, {:error, :dating_disabled}),
    do: ErrorResponse.forbidden(conn, "dating.disabled", "Enable Dating in settings first")

  defp handle_error(conn, {:error, :dating_profile_incomplete}),
    do:
      ErrorResponse.unprocessable_entity(
        conn,
        "dating.profile_incomplete",
        "Add your birthday, gender, interests, at least two photos, and a location to enable Dating"
      )

  defp handle_error(conn, {:error, :dating_dob_locked}),
    do:
      ErrorResponse.forbidden(
        conn,
        "dating.dob_locked",
        "Your date of birth can no longer be changed"
      )

  defp handle_error(conn, {:error, :dating_photo_not_owned}),
    do:
      ErrorResponse.unprocessable_entity(
        conn,
        "dating.photo_not_owned",
        "Photos must be your own uploads"
      )

  defp handle_error(conn, {:error, :dating_self_swipe}),
    do: ErrorResponse.unprocessable_entity(conn, "dating.self_swipe", "You cannot swipe yourself")

  defp handle_error(conn, {:error, :dating_matched}),
    do:
      ErrorResponse.conflict(
        conn,
        "dating.matched",
        "You are matched — unmatch instead of passing"
      )

  defp handle_error(conn, {:error, :dating_match_not_found}),
    do: ErrorResponse.not_found(conn, "dating.match_not_found", "Match not found")

  defp handle_error(conn, {:error, :dating_blocked}),
    do: ErrorResponse.not_found(conn, "dating.not_available", "This person is not available")

  defp handle_error(conn, _), do: ErrorResponse.invalid_request(conn, "dating.invalid")

  defp session_app(session), do: Map.get(session, :app_id) || Map.get(session, "app_id")
  defp mget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp mget(_, _), do: nil
end
