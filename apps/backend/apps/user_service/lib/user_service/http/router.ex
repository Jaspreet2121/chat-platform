defmodule UserService.HTTP.Router do
  @moduledoc """
  Internal HTTP API for user-service (Plug, not Phoenix). Routes map 1:1 to
  `SharedInfra.UserClient`'s contract; each calls the in-process `UserService.Profiles` function
  and serializes via `SharedInfra.InternalApi.encode_result/1` (preserving the `:profile_invalid`
  error atom + atom-keyed profile maps). Same template as `AuthService.HTTP.Router`. Transport auth
  via `SharedInfra.InternalApi.TokenPlug`.

  Started ONLY under `USER_HTTP_API_ENABLED` (see `UserService.Application`), default off → no
  listener at boot. See docs/09-devops/INTERNAL_API.md.
  """
  use Plug.Router

  plug(SharedInfra.InternalApi.TokenPlug)
  plug(SharedInfra.InternalApi.CorrelationPlug)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:dispatch)

  post "/internal/profiles/current" do
    send_result(conn, UserService.Profiles.get_current_profile(body(conn)))
  end

  post "/internal/profiles/public" do
    send_result(conn, UserService.Profiles.get_public_profile(body(conn)))
  end

  post "/internal/users/search" do
    send_result(conn, UserService.Profiles.search_users(body(conn)))
  end

  post "/internal/quick_replies/list" do
    send_result(conn, UserService.QuickReplies.list(body(conn)))
  end

  post "/internal/quick_replies/create" do
    send_result(conn, UserService.QuickReplies.create(body(conn)))
  end

  post "/internal/quick_replies/update" do
    send_result(conn, UserService.QuickReplies.update(body(conn)))
  end

  post "/internal/quick_replies/delete" do
    send_result(conn, UserService.QuickReplies.delete(body(conn)))
  end

  post "/internal/quick_replies/reorder" do
    send_result(conn, UserService.QuickReplies.reorder(body(conn)))
  end

  post "/internal/profiles/update" do
    send_result(conn, UserService.Profiles.update_current_profile(body(conn)))
  end

  post "/internal/privacy/last_seen_visibility" do
    send_result(conn, UserService.Privacy.last_seen_visibility(body(conn)))
  end

  post "/internal/privacy/get" do
    send_result(conn, UserService.Privacy.get_privacy(body(conn)))
  end

  # Usernames (080) — app-scoped resolution + availability (session + rate limit live in the gateway).
  post "/internal/favourites/list" do
    send_result(conn, UserService.FavouriteContacts.list(body(conn)))
  end

  post "/internal/favourites/add" do
    send_result(conn, UserService.FavouriteContacts.add(body(conn)))
  end

  post "/internal/favourites/remove" do
    send_result(conn, UserService.FavouriteContacts.remove(body(conn)))
  end

  post "/internal/favourites/reorder" do
    send_result(conn, UserService.FavouriteContacts.reorder(body(conn)))
  end

  post "/internal/usernames/lookup" do
    send_result(conn, UserService.Usernames.lookup(body(conn)))
  end

  post "/internal/usernames/check" do
    send_result(conn, UserService.Usernames.check_availability(body(conn)))
  end

  post "/internal/privacy/update" do
    send_result(conn, UserService.Privacy.update_privacy(body(conn)))
  end

  post "/internal/nearby/discover" do
    send_result(conn, UserService.Nearby.discover(body(conn)))
  end

  post "/internal/nearby/stop" do
    send_result(conn, UserService.Nearby.stop(body(conn)))
  end

  post "/internal/nearby/requests/create" do
    send_result(conn, UserService.Nearby.send_request(body(conn)))
  end

  post "/internal/nearby/requests/list" do
    send_result(conn, UserService.Nearby.list_requests(body(conn)))
  end

  post "/internal/nearby/settings/get" do
    send_result(conn, UserService.Nearby.get_settings(body(conn)))
  end

  post "/internal/nearby/settings/update" do
    send_result(conn, UserService.Nearby.update_settings(body(conn)))
  end

  post "/internal/dating/profile/get" do
    send_result(conn, UserService.Dating.get_profile(body(conn)))
  end

  post "/internal/dating/profile/update" do
    send_result(conn, UserService.Dating.update_profile(body(conn)))
  end

  post "/internal/dating/deck" do
    send_result(conn, UserService.Dating.deck(body(conn)))
  end

  post "/internal/dating/swipe" do
    send_result(conn, UserService.Dating.swipe(body(conn)))
  end

  post "/internal/dating/likes" do
    send_result(conn, UserService.Dating.likes(body(conn)))
  end

  post "/internal/dating/matches" do
    send_result(conn, UserService.Dating.matches(body(conn)))
  end

  post "/internal/dating/unmatch" do
    send_result(conn, UserService.Dating.unmatch(body(conn)))
  end

  post "/internal/dating/unmatch_pair" do
    send_result(conn, UserService.Dating.unmatch_pair(body(conn)))
  end

  post "/internal/dating/attach_conversation" do
    send_result(conn, UserService.Dating.attach_match_conversation(body(conn)))
  end

  post "/internal/nearby/ble/admit" do
    send_result(conn, UserService.Nearby.admit_ble_targets(body(conn)))
  end

  post "/internal/nearby/requests/respond" do
    send_result(conn, UserService.Nearby.respond(body(conn)))
  end

  post "/internal/auto_replies/get" do
    send_result(conn, UserService.AutoReplies.get_settings(body(conn)))
  end

  post "/internal/auto_replies/update" do
    send_result(conn, UserService.AutoReplies.update_settings(body(conn)))
  end

  post "/internal/auto_replies/claim" do
    send_result(conn, UserService.AutoReplies.claim(body(conn)))
  end

  get "/internal/health" do
    send_result(conn, {:ok, %{service: "user", status: "ok", deps: %{}}})
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{"error" => "not_found"}))
  end

  defp body(%{body_params: params}) when is_map(params) and not is_struct(params), do: params
  defp body(_conn), do: %{}

  defp send_result(conn, result) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(SharedInfra.InternalApi.encode_result(result)))
  end
end
