defmodule MessageService.Search do
  @moduledoc """
  Message search boundary: case-insensitive ILIKE over `messages.body`, SCOPED to the caller's own
  conversations for privacy (see `MessageStore.search_messages`, which joins `conversation_participants`
  so a user can never search a conversation they're not in). Deleted messages are excluded; results are
  newest-first and paginated.

  Flag-gated like the rest: with `MESSAGE_DB_BACKED` off (plain `mix test`) it returns no results
  without a DB. The minimum-query-length guard (avoids huge scans on 0–1 char queries) lives here.
  """

  alias MessageService.Messages
  alias MessageService.MessageStore

  @min_query_length 2

  @type attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback search_messages(attrs()) :: result()

  def search_messages(attrs) do
    query = String.trim(to_string(Map.get(attrs, "query") || Map.get(attrs, "q") || ""))

    cond do
      String.length(query) < @min_query_length ->
        {:error, :query_too_short}

      not persistence_enabled?() ->
        {:ok, %{messages: [], query: query, next_cursor: nil}}

      true ->
        run_search(attrs, query)
    end
  end

  defp run_search(attrs, query) do
    with {:ok, user_id} <- required(attrs, "user_id") do
      case MessageStore.search_messages(%{
             "user_id" => user_id,
             "query" => query,
             "page" => page(attrs)
           }) do
        {:ok, listing} ->
          {:ok,
           %{
             messages: Enum.map(listing.messages, &Messages.message_response/1),
             query: query,
             next_cursor: nil
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp required(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :search_invalid}
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
