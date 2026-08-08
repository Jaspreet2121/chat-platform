defmodule MessageService.HTTP.Router do
  @moduledoc """
  Internal HTTP API for message-service (Plug, not Phoenix) — the heaviest (9 routes). Routes map
  1:1 to `SharedInfra.MessageClient`'s contract; each calls the in-process
  `MessageService.{Messages,Timeline,Receipts}` function and serializes via
  `SharedInfra.InternalApi.encode_result/1` (preserving error atoms `:message_invalid`,
  `:message_forbidden`). `list_timeline` maps to `Timeline.list_messages/1` (distinct from
  `Messages.list_messages/1`), matching the client function names. Transport auth via
  `SharedInfra.InternalApi.TokenPlug`.

  Started ONLY under `MESSAGE_HTTP_API_ENABLED` (see `MessageService.Application`), default off → no
  listener at boot. See docs/09-devops/INTERNAL_API.md.
  """
  use Plug.Router

  plug(SharedInfra.InternalApi.TokenPlug)
  plug(SharedInfra.InternalApi.CorrelationPlug)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:dispatch)

  post "/internal/messages/create" do
    send_result(conn, MessageService.Messages.create_message(body(conn)))
  end

  post "/internal/messages/send" do
    send_result(conn, MessageService.Messages.send_message(body(conn)))
  end

  post "/internal/messages/list_media" do
    send_result(conn, MessageService.MessageStore.list_media(body(conn)))
  end

  post "/internal/messages/by_media_id" do
    send_result(conn, MessageService.MessageStore.get_by_media_id(body(conn)))
  end

  post "/internal/messages/get" do
    send_result(conn, MessageService.MessageStore.get_message(body(conn)))
  end

  post "/internal/messages/list" do
    send_result(conn, MessageService.Messages.list_messages(body(conn)))
  end

  post "/internal/messages/update" do
    send_result(conn, MessageService.Messages.update_message(body(conn)))
  end

  post "/internal/messages/edit" do
    send_result(conn, MessageService.Messages.edit_message(body(conn)))
  end

  post "/internal/messages/delete" do
    send_result(conn, MessageService.Messages.delete_message(body(conn)))
  end

  post "/internal/messages/admin_delete" do
    send_result(conn, MessageService.Messages.admin_delete_message(body(conn)))
  end

  post "/internal/reactions/add" do
    send_result(conn, MessageService.Reactions.add_reaction(body(conn)))
  end

  post "/internal/reactions/remove" do
    send_result(conn, MessageService.Reactions.remove_reaction(body(conn)))
  end

  post "/internal/stars/add" do
    send_result(conn, MessageService.Stars.star_message(body(conn)))
  end

  post "/internal/stars/remove" do
    send_result(conn, MessageService.Stars.unstar_message(body(conn)))
  end

  post "/internal/stars/list" do
    send_result(conn, MessageService.Stars.list_starred(body(conn)))
  end

  post "/internal/messages/pin" do
    send_result(conn, MessageService.Pins.pin_message(body(conn)))
  end

  post "/internal/messages/unpin" do
    send_result(conn, MessageService.Pins.unpin_message(body(conn)))
  end

  post "/internal/messages/pins" do
    send_result(conn, MessageService.Pins.list_pins(body(conn)))
  end

  post "/internal/search/messages" do
    send_result(conn, MessageService.Search.search_messages(body(conn)))
  end

  # list_timeline → Timeline.list_messages (distinct from Messages.list_messages above).
  post "/internal/timeline/list" do
    send_result(conn, MessageService.Timeline.list_messages(body(conn)))
  end

  post "/internal/receipts/mark_read" do
    send_result(conn, MessageService.Receipts.mark_read(body(conn)))
  end

  post "/internal/receipts/mark_delivered" do
    send_result(conn, MessageService.Receipts.mark_delivered(body(conn)))
  end

  # Message info — per-user delivery/read state (sender-only, enforced in the store).
  post "/internal/receipts/info" do
    send_result(conn, MessageService.Messages.message_info(body(conn)))
  end

  # Polls — vote (replace-the-set) + the uncapped voter lists (membership gated in the gateway).
  post "/internal/polls/vote" do
    send_result(conn, MessageService.Polls.vote(body(conn)))
  end

  post "/internal/polls/votes" do
    send_result(conn, MessageService.Polls.list_votes(body(conn)))
  end

  # Status (082) — session + purpose gates live in the gateway.
  post "/internal/status/post" do
    send_result(conn, MessageService.Statuses.post_status(body(conn)))
  end

  post "/internal/status/feed" do
    send_result(conn, MessageService.Statuses.feed(body(conn)))
  end

  post "/internal/status/list" do
    send_result(conn, MessageService.Statuses.list_posts(body(conn)))
  end

  post "/internal/status/delete" do
    send_result(conn, MessageService.Statuses.delete_status(body(conn)))
  end

  post "/internal/status/media_allowed" do
    send_result(conn, MessageService.Statuses.media_allowed(body(conn)))
  end

  post "/internal/status/audience/get" do
    send_result(conn, MessageService.Statuses.get_audience(body(conn)))
  end

  post "/internal/status/audience/set" do
    send_result(conn, MessageService.Statuses.set_audience(body(conn)))
  end

  post "/internal/status/view" do
    send_result(conn, MessageService.Statuses.record_view(body(conn)))
  end

  post "/internal/status/viewers" do
    send_result(conn, MessageService.Statuses.viewers(body(conn)))
  end

  post "/internal/status/mine" do
    send_result(conn, MessageService.Statuses.my_status(body(conn)))
  end

  post "/internal/status/for_reply" do
    send_result(conn, MessageService.Statuses.status_for_reply(body(conn)))
  end

  # Owner-anchored message-media download authorization (the gateway's "message" purpose arm).
  post "/internal/media/download_allowed" do
    send_result(conn, MessageService.MessageStore.media_download_allowed(body(conn)))
  end

  # Read-only admin analytics (gated upstream by the gateway's RequireAdmin + the internal TokenPlug).
  post "/internal/analytics/overview" do
    send_result(conn, {:ok, MessageService.Analytics.overview(Map.get(body(conn), "app_id"))})
  end

  post "/internal/analytics/timeseries" do
    days = MessageService.Analytics.normalize_days(Map.get(body(conn), "days"))

    send_result(
      conn,
      {:ok, MessageService.Analytics.timeseries(days, Map.get(body(conn), "app_id"))}
    )
  end

  # Service health: own liveness + the dependencies this service owns (Postgres store + Kafka).
  get "/internal/health" do
    deps = %{
      postgres: SharedInfra.Health.postgres(MessageService.Repo),
      kafka: SharedInfra.Health.kafka(System.get_env("KAFKA_BROKERS") || "localhost:9092")
    }

    send_result(conn, {:ok, %{service: "message", status: "ok", deps: deps}})
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
