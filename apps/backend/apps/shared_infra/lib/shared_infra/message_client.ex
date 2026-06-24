defmodule SharedInfra.MessageClient do
  @moduledoc """
  Client boundary for the Message service — lets edge apps (api_gateway, realtime_gateway)
  stop calling `MessageService.*` in-process directly. The heaviest seam (most call-sites,
  both edges).

  Same pattern as the other `SharedInfra.*Client`s: behaviour AND configured dispatcher.
  Adapter from `:shared_infra, :message_client_adapter` (config default
  `MessageService.MessageClientInProcess`, delegates in-process → zero behavior change). A
  future `MESSAGE_CLIENT_ADAPTER=http` selects an HTTP adapter (separate message-service
  container) WITHOUT touching call sites. shared_infra resolves the adapter from config at
  runtime, so it stays free of a service dependency.

  `list_timeline/1` maps to `MessageService.Timeline.list_messages/1` (distinct from
  `MessageService.Messages.list_messages/1`, exposed here as `list_messages/1`).
  """

  @type attrs :: map()
  @type result :: {:ok, map()} | {:error, term()}

  @callback create_message(attrs()) :: result()
  @callback send_message(attrs()) :: result()
  @callback list_messages(attrs()) :: result()
  @callback list_timeline(attrs()) :: result()
  @callback update_message(attrs()) :: result()
  @callback edit_message(attrs()) :: result()
  @callback delete_message(attrs()) :: result()
  @callback mark_read(attrs()) :: result()
  @callback mark_delivered(attrs()) :: result()
  @callback analytics_overview(attrs()) :: result()
  @callback analytics_timeseries(attrs()) :: result()

  def create_message(attrs), do: adapter().create_message(attrs)
  def send_message(attrs), do: adapter().send_message(attrs)
  def list_messages(attrs), do: adapter().list_messages(attrs)
  def list_timeline(attrs), do: adapter().list_timeline(attrs)
  def update_message(attrs), do: adapter().update_message(attrs)
  def edit_message(attrs), do: adapter().edit_message(attrs)
  def delete_message(attrs), do: adapter().delete_message(attrs)
  def mark_read(attrs), do: adapter().mark_read(attrs)
  def mark_delivered(attrs), do: adapter().mark_delivered(attrs)
  def analytics_overview(attrs), do: adapter().analytics_overview(attrs)
  def analytics_timeseries(attrs), do: adapter().analytics_timeseries(attrs)

  @doc "The configured Message client adapter (default `MessageService.MessageClientInProcess`)."
  def adapter do
    Application.get_env(:shared_infra, :message_client_adapter, MessageService.MessageClientInProcess)
  end
end
