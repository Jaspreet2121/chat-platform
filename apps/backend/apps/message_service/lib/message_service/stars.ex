defmodule MessageService.Stars do
  @moduledoc """
  Starred / bookmarked messages boundary — per-user and PRIVATE (no realtime, unlike reactions).

  Persistence is flag-gated like reactions: with `MESSAGE_DB_BACKED` off (plain `mix test`) star/unstar
  return an idempotent placeholder and the Starred list is empty (no DB). The per-message `is_starred`
  flag is surfaced on the timeline by the list path (see `MessageStore`), like `my_reaction`.
  """

  alias MessageService.Messages
  alias MessageService.MessageStore

  @type attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback star_message(attrs()) :: result()
  @callback unstar_message(attrs()) :: result()
  @callback list_starred(attrs()) :: result()

  def star_message(attrs) do
    if persistence_enabled?() do
      with {:ok, user_id} <- required(attrs, "user_id"),
           {:ok, message_id} <- required(attrs, "message_id"),
           {:ok, conversation_id} <- required(attrs, "conversation_id") do
        MessageStore.star_message(%{
          "user_id" => user_id,
          "message_id" => message_id,
          "conversation_id" => conversation_id
        })
      end
    else
      {:ok, %{message_id: Map.get(attrs, "message_id", "msg_placeholder"), is_starred: true}}
    end
  end

  def unstar_message(attrs) do
    if persistence_enabled?() do
      with {:ok, user_id} <- required(attrs, "user_id"),
           {:ok, message_id} <- required(attrs, "message_id") do
        MessageStore.unstar_message(%{"user_id" => user_id, "message_id" => message_id})
      end
    else
      {:ok, %{message_id: Map.get(attrs, "message_id", "msg_placeholder"), is_starred: false}}
    end
  end

  def list_starred(attrs) do
    if persistence_enabled?() do
      with {:ok, user_id} <- required(attrs, "user_id") do
        case MessageStore.list_starred(%{"user_id" => user_id, "page" => page(attrs)}) do
          {:ok, listing} ->
            {:ok, %{listing | messages: Enum.map(listing.messages, &Messages.message_response/1)}}

          {:error, reason} ->
            {:error, reason}
        end
      end
    else
      {:ok, %{messages: [], next_cursor: nil}}
    end
  end

  defp required(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :star_invalid}
    end
  end

  defp page(attrs), do: normalize_page(Map.get(attrs, "page"))

  defp normalize_page(value) when is_integer(value) and value > 0, do: value

  defp normalize_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  defp normalize_page(_), do: 1

  defp persistence_enabled? do
    Application.get_env(:message_service, :message_persistence, false) ||
      System.get_env("MESSAGE_DB_BACKED") in ["true", "1", "yes"]
  end
end
