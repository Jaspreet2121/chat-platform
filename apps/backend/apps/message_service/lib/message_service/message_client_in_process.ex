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
  def mark_delivered(attrs), do: Receipts.mark_delivered(attrs)

  @impl true
  def analytics_overview(_attrs), do: {:ok, Analytics.overview()}

  @impl true
  def analytics_timeseries(attrs),
    do: {:ok, Analytics.timeseries(Analytics.normalize_days(Map.get(attrs, "days")))}

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
  def list_media(attrs), do: MessageService.MessageStore.list_media(attrs)

  @impl true
  def get_by_media_id(attrs), do: MessageService.MessageStore.get_by_media_id(attrs)
end
