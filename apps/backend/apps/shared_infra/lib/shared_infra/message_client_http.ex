defmodule SharedInfra.MessageClientHttp do
  @moduledoc """
  HTTP adapter for `SharedInfra.MessageClient` — calls message-service's internal HTTP API
  (`MessageService.HTTP.Router`) over the network. Selected by `MESSAGE_CLIENT_ADAPTER=http`; default
  stays `MessageService.MessageClientInProcess` (zero behavior change until flipped).

  ⚠️ METADATA CAVEAT: a message's `metadata` is a FREE-FORM, user-provided, string-keyed map. Every
  call decodes with `skip_atomize: ["metadata"]` so `metadata`'s value stays string-keyed (matching
  in-process) and arbitrary atoms are never minted from user input. The rest of the message
  (atom-keyed) is atomized normally; `skip_atomize` matches `"metadata"` at any depth (incl. inside
  the `messages` list of list/timeline responses). Transport failure → `{:error, :message_unavailable}`.
  `list_timeline` maps to `/internal/timeline/list` (the `Timeline.list_messages` route). Base URL from
  `MESSAGE_SERVICE_URL`.
  """

  @behaviour SharedInfra.MessageClient

  @unavailable :message_unavailable
  @decode [skip_atomize: ["metadata"]]

  @impl true
  def create_message(attrs), do: post("/internal/messages/create", attrs)

  @impl true
  def send_message(attrs), do: post("/internal/messages/send", attrs)

  @impl true
  def list_messages(attrs), do: post("/internal/messages/list", attrs)

  @impl true
  def list_timeline(attrs), do: post("/internal/timeline/list", attrs)

  @impl true
  def update_message(attrs), do: post("/internal/messages/update", attrs)

  @impl true
  def edit_message(attrs), do: post("/internal/messages/edit", attrs)

  @impl true
  def delete_message(attrs), do: post("/internal/messages/delete", attrs)

  @impl true
  def mark_read(attrs), do: post("/internal/receipts/mark_read", attrs)

  @impl true
  def message_info(attrs), do: post("/internal/receipts/info", attrs)

  @impl true
  def vote_poll(attrs), do: post("/internal/polls/vote", attrs)

  @impl true
  def list_poll_votes(attrs), do: post("/internal/polls/votes", attrs)

  @impl true
  def mark_delivered(attrs), do: post("/internal/receipts/mark_delivered", attrs)

  @impl true
  def analytics_overview(attrs), do: post("/internal/analytics/overview", attrs)

  @impl true
  def analytics_timeseries(attrs), do: post("/internal/analytics/timeseries", attrs)

  @impl true
  def admin_delete_message(attrs), do: post("/internal/messages/admin_delete", attrs)

  @impl true
  def add_reaction(attrs), do: post("/internal/reactions/add", attrs)

  @impl true
  def remove_reaction(attrs), do: post("/internal/reactions/remove", attrs)

  @impl true
  def star_message(attrs), do: post("/internal/stars/add", attrs)

  @impl true
  def unstar_message(attrs), do: post("/internal/stars/remove", attrs)

  @impl true
  def list_starred(attrs), do: post("/internal/stars/list", attrs)

  @impl true
  def search_messages(attrs), do: post("/internal/search/messages", attrs)

  @impl true
  def list_media(attrs), do: post("/internal/messages/list_media", attrs)

  @impl true
  def get_by_media_id(attrs), do: post("/internal/messages/by_media_id", attrs)

  defp post(path, attrs) do
    SharedInfra.HttpClient.post_result(base_url(), path, attrs,
      unavailable: @unavailable,
      decode: @decode
    )
  end

  defp base_url do
    Application.get_env(:shared_infra, :message_service_url) ||
      System.get_env("MESSAGE_SERVICE_URL") || "http://localhost:4104"
  end
end
