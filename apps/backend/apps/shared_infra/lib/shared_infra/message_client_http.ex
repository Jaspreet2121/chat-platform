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
  def mark_delivered(attrs), do: post("/internal/receipts/mark_delivered", attrs)

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
