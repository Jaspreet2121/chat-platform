defmodule ApiGatewayWeb.FavouriteController do
  @moduledoc """
  FAVOURITE CONTACTS — the Calls tab's favourites, server-side (090). Owner-scoped by the session,
  never by a client-supplied id.

  THE ENRICHED READ is ProfilePresenter's FIFTH consumer (profile, by-phone, avatar redirect,
  contacts sync, and now this): each favourite carries user_id + display_name + avatar_url so a chip
  renders with ZERO client round-trips, and block + photo-visibility redaction apply EXACTLY as on
  every other surface — a blocked favourite remains listed, redacted, until its owner removes it
  (blocks never delete relationships). Cost is bounded by the 20-favourite cap, the same class as
  contact sync's per-match enrichment.

  Propagation is fetch-on-open by design — no event, no inbox riding; see FavouriteContacts.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse
  alias ApiGatewayWeb.ProfilePresenter

  @limit 20

  def index(conn, _params) do
    with_session(conn, fn session ->
      with {:ok, %{favourites: favourites}} <-
             SharedInfra.UserClient.list_favourites(%{"owner_user_id" => session.user_id}) do
        {:ok, %{favourites: Enum.map(favourites, &enrich(&1, session))}}
      end
    end)
  end

  def create(conn, %{"user_id" => target}) do
    with_session(conn, fn session ->
      SharedInfra.UserClient.add_favourite(%{
        "owner_user_id" => session.user_id,
        "favourite_user_id" => target,
        "app_id" => session_app(session)
      })
    end)
  end

  def create(conn, _params), do: ErrorResponse.invalid_request(conn, "favourites.invalid")

  def delete(conn, %{"user_id" => target}) do
    with_session(conn, fn session ->
      SharedInfra.UserClient.remove_favourite(%{
        "owner_user_id" => session.user_id,
        "favourite_user_id" => target
      })
    end)
  end

  def reorder(conn, %{"favourite_user_ids" => ids}) do
    with_session(conn, fn session ->
      SharedInfra.UserClient.reorder_favourites(%{
        "owner_user_id" => session.user_id,
        "favourite_user_ids" => ids
      })
    end)
  end

  def reorder(conn, _params), do: ErrorResponse.invalid_request(conn, "favourites.invalid")

  # The contact-sync enrich shape, verbatim semantics: public profile -> presenter -> the chip
  # fields. A profile miss degrades that one chip (name nil, avatar nil), never the list.
  defp enrich(favourite, session) do
    base = %{user_id: favourite.user_id, position: favourite.position}

    case SharedInfra.UserClient.get_public_profile(%{
           "user_id" => favourite.user_id,
           "app_id" => session_app(session)
         }) do
      {:ok, profile} ->
        presented = ProfilePresenter.present(session.user_id, favourite.user_id, profile)

        Map.merge(base, %{
          display_name: Map.get(presented, :display_name),
          avatar_url: Map.get(presented, :avatar_url)
        })

      _ ->
        Map.merge(base, %{display_name: nil, avatar_url: nil})
    end
  end

  defp with_session(conn, operation) do
    with {:ok, authorization} <- authorization_header(conn),
         {:ok, session} <-
           SharedInfra.AuthClient.current_session(%{"authorization" => authorization}),
         {:ok, response} <- operation.(session) do
      json(conn, response)
    else
      {:error, :session_invalid} ->
        ErrorResponse.unauthorized(conn, "auth.session_invalid", "Invalid or expired session")

      {:error, :auth_unavailable} ->
        ErrorResponse.service_unavailable(conn, "auth.unavailable")

      {:error, :user_unavailable} ->
        ErrorResponse.service_unavailable(conn, "favourites.unavailable")

      {:error, :favourite_limit} ->
        ErrorResponse.invalid_request_with(conn, "favourites.limit", "Too many favourites", %{
          limit: @limit
        })

      {:error, :favourite_unknown_user} ->
        ErrorResponse.not_found(conn, "favourites.unknown_user", "User not found")

      _ ->
        ErrorResponse.invalid_request(conn, "favourites.invalid")
    end
  end

  defp session_app(session), do: Map.get(session, :app_id) || Map.get(session, "app_id")

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> _token = authorization] -> {:ok, authorization}
      _ -> {:error, :session_invalid}
    end
  end
end
