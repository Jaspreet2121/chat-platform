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
  @callback admin_delete_message(attrs()) :: result()
  @callback add_reaction(attrs()) :: result()
  @callback remove_reaction(attrs()) :: result()
  @callback star_message(attrs()) :: result()
  @callback unstar_message(attrs()) :: result()
  @callback list_starred(attrs()) :: result()
  @callback search_messages(attrs()) :: result()
  @callback list_media(attrs()) :: result()
  @callback get_by_media_id(attrs()) :: result()
  # Message info (per-user delivery/read state; sender-only). Optional so existing stubs don't all need it.
  @callback message_info(attrs()) :: result()
  # Polls: replace-the-set vote + the uncapped voter lists.
  @callback vote_poll(attrs()) :: result()
  @callback list_poll_votes(attrs()) :: result()
  # Status (082): posts, the one-query feed, per-owner list, owner delete, media-authz support.
  @callback post_status(attrs()) :: result()
  @callback status_feed(attrs()) :: result()
  @callback list_status_posts(attrs()) :: result()
  @callback delete_status(attrs()) :: result()
  @callback status_media_allowed(attrs()) :: result()
  # Owner-anchored message-media download authorization.
  @callback media_download_allowed(attrs()) :: result()
  @optional_callbacks message_info: 1,
                      media_download_allowed: 1,
                      vote_poll: 1,
                      list_poll_votes: 1,
                      post_status: 1,
                      status_feed: 1,
                      list_status_posts: 1,
                      delete_status: 1,
                      status_media_allowed: 1

  def create_message(attrs), do: adapter().create_message(attrs)
  def send_message(attrs), do: adapter().send_message(attrs)
  def list_messages(attrs), do: adapter().list_messages(attrs)
  def list_timeline(attrs), do: adapter().list_timeline(attrs)
  def update_message(attrs), do: adapter().update_message(attrs)
  def edit_message(attrs), do: adapter().edit_message(attrs)
  def delete_message(attrs), do: adapter().delete_message(attrs)
  def mark_read(attrs), do: adapter().mark_read(attrs)
  def message_info(attrs), do: adapter().message_info(attrs)
  def vote_poll(attrs), do: adapter().vote_poll(attrs)
  def list_poll_votes(attrs), do: adapter().list_poll_votes(attrs)
  def post_status(attrs), do: adapter().post_status(attrs)
  def status_feed(attrs), do: adapter().status_feed(attrs)
  def list_status_posts(attrs), do: adapter().list_status_posts(attrs)
  def delete_status(attrs), do: adapter().delete_status(attrs)
  def status_media_allowed(attrs), do: adapter().status_media_allowed(attrs)
  def media_download_allowed(attrs), do: adapter().media_download_allowed(attrs)
  def mark_delivered(attrs), do: adapter().mark_delivered(attrs)
  def analytics_overview(attrs), do: adapter().analytics_overview(attrs)
  def analytics_timeseries(attrs), do: adapter().analytics_timeseries(attrs)
  def admin_delete_message(attrs), do: adapter().admin_delete_message(attrs)
  def add_reaction(attrs), do: adapter().add_reaction(attrs)
  def remove_reaction(attrs), do: adapter().remove_reaction(attrs)
  def star_message(attrs), do: adapter().star_message(attrs)
  def unstar_message(attrs), do: adapter().unstar_message(attrs)
  def list_starred(attrs), do: adapter().list_starred(attrs)
  def search_messages(attrs), do: adapter().search_messages(attrs)
  def list_media(attrs), do: adapter().list_media(attrs)
  # The conversation a media_id was sent to — read-path authorization for message media.
  def get_by_media_id(attrs), do: adapter().get_by_media_id(attrs)

  @doc "The configured Message client adapter (default `MessageService.MessageClientInProcess`)."
  def adapter do
    Application.get_env(:shared_infra, :message_client_adapter, MessageService.MessageClientInProcess)
  end
end
