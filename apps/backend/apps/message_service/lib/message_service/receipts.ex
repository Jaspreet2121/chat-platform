defmodule MessageService.Receipts do
  @moduledoc """
  Message receipt boundary.

  DB-backed receipt writes are feature-gated. The current Scylla schema stores
  one receipt status plus `updated_at`, so delivered/read are exposed at the
  service boundary while richer receipt history remains future work.
  """

  alias MessageService.MessageStore

  @type receipt_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback mark_read(receipt_attrs()) :: result()
  @callback mark_delivered(receipt_attrs()) :: result()

  def mark_read(attrs) do
    if message_persistence_enabled?() do
      mark_read_in_store(attrs)
    else
      placeholder_mark_read(attrs)
    end
  end

  def mark_delivered(attrs) do
    if message_persistence_enabled?() do
      mark_delivered_in_store(attrs)
    else
      placeholder_mark_delivered(attrs)
    end
  end

  defp mark_read_in_store(attrs) do
    with {:ok, conversation_id} <- required_attr(attrs, "conversation_id"),
         {:ok, message_id} <- required_attr(attrs, "message_id"),
         {:ok, user_id} <- required_attr(attrs, "user_id") do
      read_at = now()

      receipt_attrs = %{
        "conversation_id" => conversation_id,
        "message_id" => message_id,
        "user_id" => user_id,
        "status" => "read",
        "updated_at" => read_at
      }

      case MessageStore.mark_read(receipt_attrs) do
        {:ok, receipt} -> {:ok, read_response(receipt)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp mark_delivered_in_store(attrs) do
    with {:ok, conversation_id} <- required_attr(attrs, "conversation_id"),
         {:ok, message_id} <- required_attr(attrs, "message_id"),
         {:ok, user_id} <- required_attr(attrs, "user_id") do
      delivered_at = now()

      receipt_attrs = %{
        "conversation_id" => conversation_id,
        "message_id" => message_id,
        "user_id" => user_id,
        "status" => "delivered",
        "updated_at" => delivered_at
      }

      case MessageStore.mark_delivered(receipt_attrs) do
        {:ok, receipt} -> {:ok, delivered_response(receipt)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp placeholder_mark_read(attrs) do
    {:ok,
     %{
       conversation_id: Map.get(attrs, "conversation_id", "conv_placeholder"),
       message_id: Map.get(attrs, "message_id", "msg_placeholder"),
       read_by_user_id: "user_placeholder",
       read_at: "2026-06-17T10:30:00Z"
     }}
  end

  defp placeholder_mark_delivered(attrs) do
    {:ok,
     %{
       conversation_id: Map.get(attrs, "conversation_id", "conv_placeholder"),
       message_id: Map.get(attrs, "message_id", "msg_placeholder"),
       delivered_to_user_id: "user_placeholder",
       delivered_at: "2026-06-17T10:30:00Z"
     }}
  end

  defp read_response(receipt) do
    %{
      conversation_id: receipt.conversation_id,
      message_id: receipt.message_id,
      user_id: receipt.user_id,
      read_at: iso8601(Map.get(receipt, :read_at) || receipt.updated_at)
    }
    |> maybe_put(:delivered_at, iso8601(Map.get(receipt, :delivered_at)))
  end

  defp delivered_response(receipt) do
    %{
      conversation_id: receipt.conversation_id,
      message_id: receipt.message_id,
      user_id: receipt.user_id,
      delivered_at: iso8601(Map.get(receipt, :delivered_at) || receipt.updated_at)
    }
    |> maybe_put(:read_at, iso8601(Map.get(receipt, :read_at)))
  end

  defp required_attr(attrs, key) do
    case get_attr(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :message_invalid}
    end
  end

  defp get_attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))

  defp message_persistence_enabled? do
    Application.get_env(:message_service, :message_persistence, false) ||
      System.get_env("MESSAGE_DB_BACKED") in ["true", "1", "yes"]
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(value), do: value
end
