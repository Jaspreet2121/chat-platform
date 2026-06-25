defmodule MessageService.Reactions do
  @moduledoc """
  Message reaction boundary (WhatsApp model: one reaction per user per message, changeable).

  Persistence is flag-gated like receipts: with `MESSAGE_DB_BACKED` off (plain `mix test`) it takes a
  placeholder path with no DB. Both operations return the message's new aggregate
  (`%{message_id, reactions: [%{emoji, count}]}`) so the caller (gateway / realtime) can echo + broadcast it.
  """

  alias MessageService.MessageStore

  @type reaction_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback add_reaction(reaction_attrs()) :: result()
  @callback remove_reaction(reaction_attrs()) :: result()

  def add_reaction(attrs) do
    if persistence_enabled?() do
      with {:ok, conversation_id} <- required(attrs, "conversation_id"),
           {:ok, message_id} <- required(attrs, "message_id"),
           {:ok, user_id} <- required(attrs, "user_id"),
           {:ok, emoji} <- required(attrs, "emoji") do
        MessageStore.upsert_reaction(%{
          "conversation_id" => conversation_id,
          "message_id" => message_id,
          "user_id" => user_id,
          "emoji" => emoji
        })
      end
    else
      {:ok, placeholder(attrs)}
    end
  end

  def remove_reaction(attrs) do
    if persistence_enabled?() do
      with {:ok, message_id} <- required(attrs, "message_id"),
           {:ok, user_id} <- required(attrs, "user_id") do
        MessageStore.remove_reaction(%{"message_id" => message_id, "user_id" => user_id})
      end
    else
      {:ok, placeholder(attrs)}
    end
  end

  defp placeholder(attrs) do
    %{message_id: Map.get(attrs, "message_id", "msg_placeholder"), reactions: []}
  end

  defp required(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :reaction_invalid}
    end
  end

  defp persistence_enabled? do
    Application.get_env(:message_service, :message_persistence, false) ||
      System.get_env("MESSAGE_DB_BACKED") in ["true", "1", "yes"]
  end
end
