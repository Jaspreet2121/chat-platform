defmodule MessageService.MessageClientInProcess do
  @moduledoc """
  In-process adapter for `SharedInfra.MessageClient` — the default. Delegates straight to the
  existing `MessageService.{Messages,Timeline,Receipts}` functions, returning the SAME shapes,
  so routing edge apps through the client boundary is a zero-behavior-change refactor. A future
  HTTP adapter (separate message-service container) implements the same behaviour.
  """

  @behaviour SharedInfra.MessageClient

  alias MessageService.Analytics
  alias MessageService.Messages
  alias MessageService.Reactions
  alias MessageService.Receipts
  alias MessageService.Search
  alias MessageService.Stars
  alias MessageService.Timeline

  @impl true
  def create_message(attrs), do: Messages.create_message(attrs)

  @impl true
  def send_message(attrs), do: Messages.send_message(attrs)

  @impl true
  def list_messages(attrs), do: Messages.list_messages(attrs)

  @impl true
  def list_timeline(attrs), do: Timeline.list_messages(attrs)

  @impl true
  def update_message(attrs), do: Messages.update_message(attrs)

  @impl true
  def edit_message(attrs), do: Messages.edit_message(attrs)

  @impl true
  def delete_message(attrs), do: Messages.delete_message(attrs)

  @impl true
  def mark_read(attrs), do: Receipts.mark_read(attrs)

  @impl true
  def message_info(attrs), do: MessageService.Messages.message_info(attrs)

  # Straight to the STORE, not to `Messages` — the point of this callback is to read through whichever
  # store adapter is configured. Same target as the `/internal/messages/get` route, so both adapters
  # return the same shape (`MessageClientHttpIntegrationTest` asserts that equality).
  @impl true
  def get_message(attrs), do: MessageService.MessageStore.get_message(attrs)

  @impl true
  def event_outbox_summary(attrs), do: MessageService.EventOutboxOps.summary(attrs)

  @impl true
  def event_outbox_list(attrs), do: MessageService.EventOutboxOps.list(attrs)

  @impl true
  def event_outbox_get(attrs), do: MessageService.EventOutboxOps.get(attrs)

  @impl true
  def event_outbox_acknowledge(attrs), do: MessageService.EventOutboxOps.acknowledge(attrs)

  @impl true
  def vote_poll(attrs), do: MessageService.Polls.vote(attrs)

  @impl true
  def list_poll_votes(attrs), do: MessageService.Polls.list_votes(attrs)

  @impl true
  def post_status(attrs), do: MessageService.Statuses.post_status(attrs)

  @impl true
  def status_feed(attrs), do: MessageService.Statuses.feed(attrs)

  @impl true
  def list_status_posts(attrs), do: MessageService.Statuses.list_posts(attrs)

  @impl true
  def delete_status(attrs), do: MessageService.Statuses.delete_status(attrs)

  @impl true
  def status_media_allowed(attrs), do: MessageService.Statuses.media_allowed(attrs)

  @impl true
  def get_status_audience(attrs), do: MessageService.Statuses.get_audience(attrs)

  @impl true
  def set_status_audience(attrs), do: MessageService.Statuses.set_audience(attrs)

  @impl true
  def get_status_settings(attrs), do: MessageService.Statuses.get_settings(attrs)

  @impl true
  def set_status_settings(attrs), do: MessageService.Statuses.set_settings(attrs)

  @impl true
  def record_status_view(attrs), do: MessageService.Statuses.record_view(attrs)

  @impl true
  def status_viewers(attrs), do: MessageService.Statuses.viewers(attrs)

  @impl true
  def my_status(attrs), do: MessageService.Statuses.my_status(attrs)

  @impl true
  def status_for_reply(attrs), do: MessageService.Statuses.status_for_reply(attrs)

  @impl true
  def media_download_allowed(attrs), do: MessageService.MessageStore.media_download_allowed(attrs)

  @impl true
  def view_once_state(attrs) do
    state =
      MessageService.ViewOnce.state(
        Map.get(attrs, "media_id"),
        Map.get(attrs, "viewer_user_id")
      )

    {:ok, %{state: Atom.to_string(state)}}
  end

  @impl true
  def open_view_once(attrs) do
    case MessageService.ViewOnce.open(
           Map.get(attrs, "conversation_id"),
           Map.get(attrs, "message_id"),
           Map.get(attrs, "viewer_user_id")
         ) do
      {:ok, result} -> {:ok, Map.put(result, :first_open, result.first_open?)}
      error -> error
    end
  end

  @impl true
  def expired_view_once_media(_attrs),
    do: {:ok, %{media_ids: MessageService.ViewOnce.expired_unopened_media()}}

  @impl true
  def mark_delivered(attrs), do: Receipts.mark_delivered(attrs)

  @impl true
  def analytics_overview(attrs), do: {:ok, Analytics.overview(Map.get(attrs, "app_id"))}

  @impl true
  def analytics_timeseries(attrs),
    do:
      {:ok,
       Analytics.timeseries(
         Analytics.normalize_days(Map.get(attrs, "days")),
         Map.get(attrs, "app_id")
       )}

  @impl true
  def admin_delete_message(attrs), do: Messages.admin_delete_message(attrs)

  @impl true
  def add_reaction(attrs), do: Reactions.add_reaction(attrs)

  @impl true
  def remove_reaction(attrs), do: Reactions.remove_reaction(attrs)

  @impl true
  def star_message(attrs), do: Stars.star_message(attrs)

  @impl true
  def unstar_message(attrs), do: Stars.unstar_message(attrs)

  @impl true
  def list_starred(attrs), do: Stars.list_starred(attrs)

  @impl true
  def search_messages(attrs), do: Search.search_messages(attrs)

  @impl true
  def pin_message(attrs), do: MessageService.Pins.pin_message(attrs)

  @impl true
  def unpin_message(attrs), do: MessageService.Pins.unpin_message(attrs)

  @impl true
  def list_pins(attrs), do: MessageService.Pins.list_pins(attrs)

  @impl true
  def list_media(attrs), do: MessageService.MessageStore.list_media(attrs)

  @impl true
  def get_by_media_id(attrs), do: MessageService.MessageStore.get_by_media_id(attrs)
end
