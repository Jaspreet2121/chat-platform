defmodule MessageService.Messages do
  @moduledoc """
  Message creation, edit, and delete boundary.

  DB-backed create/list behavior is feature-gated. Live ScyllaDB writes,
  sender ownership enforcement, and rate limits are future work. `message.created.v1`
  is published fire-and-forget after a successful create when Kafka publishing is enabled.
  """

  require Logger

  alias MessageService.MessageStore
  alias SharedInfra.Events.Envelope
  alias SharedInfra.Kafka.Producer

  @message_topic "message.events.v1"

  @type message_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback create_message(message_attrs()) :: result()
  @callback list_messages(message_attrs()) :: result()
  @callback update_message(message_attrs()) :: result()
  @callback send_message(message_attrs()) :: result()
  @callback edit_message(message_attrs()) :: result()
  @callback delete_message(message_attrs()) :: result()

  def create_message(attrs) do
    if message_persistence_enabled?() do
      create_message_in_store(attrs)
    else
      placeholder_send_message(attrs)
    end
  end

  def list_messages(attrs) do
    if message_persistence_enabled?() do
      list_messages_from_store(attrs)
    else
      placeholder_list_messages(attrs)
    end
  end

  def send_message(attrs) do
    create_message(attrs)
  end

  def update_message(attrs) do
    if message_persistence_enabled?() do
      update_message_in_store(attrs)
    else
      placeholder_edit_message(attrs)
    end
  end

  def edit_message(attrs) do
    update_message(attrs)
  end

  def delete_message(attrs) do
    if message_persistence_enabled?() do
      delete_message_in_store(attrs)
    else
      placeholder_delete_message(attrs)
    end
  end

  def message_persistence_enabled? do
    Application.get_env(:message_service, :message_persistence, false) ||
      System.get_env("MESSAGE_DB_BACKED") in ["true", "1", "yes"]
  end

  defp placeholder_edit_message(attrs) do
    {:ok,
     %{
       conversation_id: Map.get(attrs, "conversation_id", "conv_placeholder"),
       message_id: Map.get(attrs, "message_id", "msg_placeholder"),
       body: Map.get(attrs, "body", "Hello edited"),
       status: "edited",
       edited_at: "2026-06-17T10:20:00Z"
     }}
  end

  defp placeholder_delete_message(attrs) do
    {:ok,
     %{
       conversation_id: Map.get(attrs, "conversation_id", "conv_placeholder"),
       message_id: Map.get(attrs, "message_id", "msg_placeholder"),
       status: "deleted",
       deleted_at: "2026-06-17T10:25:00Z"
     }}
  end

  defp create_message_in_store(attrs) do
    with {:ok, conversation_id} <- required_attr(attrs, "conversation_id"),
         {:ok, sender_user_id} <- required_attr(attrs, "sender_user_id"),
         {:ok, message_type} <- required_attr(attrs, "message_type"),
         {:ok, media_id} <- media_id(attrs, message_type),
         {:ok, caption} <- caption(attrs, message_type),
         {:ok, body} <- message_body(attrs, message_type, caption),
         {:ok, metadata} <- metadata(attrs, message_type, media_id, caption) do
      created_at = now()

      message_attrs = %{
        "conversation_id" => conversation_id,
        "bucket_date" => bucket_date(created_at),
        "message_id" => generate_timeuuid(),
        "sender_user_id" => sender_user_id,
        "message_type" => message_type,
        "body" => body,
        "media_id" => media_id,
        "reply_to_message_id" => get_attr(attrs, "reply_to_message_id"),
        "status" => "active",
        "metadata" => metadata,
        "created_at" => created_at,
        "edited_at" => nil,
        "deleted_at" => nil
      }

      case MessageStore.put_message(message_attrs) do
        {:ok, message} ->
          response = message_response(message)
          publish_message_created(response)
          {:ok, response}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Fire-and-forget event publish. This MUST NOT affect message creation: the
  # {:ok, response} above is computed and returned independently, and any envelope
  # error, producer error, exception, or exit here is caught and logged — never
  # propagated. Disabled by default (KAFKA_PUBLISH_ENABLED); the default producer
  # adapter is the non-connecting NoopProducer, so nothing connects.
  defp publish_message_created(response) do
    if kafka_publish_enabled?() do
      # Capture the correlation id SYNCHRONOUSLY in THIS (caller) process — Logger metadata is
      # per-process, so reading it inside the Task below would see the Task's empty metadata and
      # lose the trace. Threaded into the closure instead.
      correlation_id = SharedInfra.Correlation.get_or_generate()

      # Task.start (unlinked) so the create path NEVER blocks on a broker — not even on a
      # lazy producer-start / metadata fetch — and a crash in the publish can't reach the
      # caller. Combined with async produce in the adapter, fire-and-forget holds for BOTH
      # correctness and latency.
      Task.start(fn -> do_publish_message_created(response, correlation_id) end)
    end

    :ok
  end

  defp do_publish_message_created(response, correlation_id) do
    case build_message_created_envelope(response, correlation_id) do
      {:ok, envelope} ->
        Producer.produce(@message_topic, response.conversation_id, envelope)

      {:error, reason} ->
        Logger.warning("message.created envelope invalid, skipping publish: #{inspect(reason)}")
    end
  rescue
    error -> Logger.warning("message.created publish raised, ignored: #{inspect(error)}")
  catch
    kind, value -> Logger.warning("message.created publish #{kind}, ignored: #{inspect(value)}")
  end

  defp build_message_created_envelope(response, correlation_id) do
    Envelope.build(%{
      event_id: Ecto.UUID.generate(),
      event_type: "message.created.v1",
      event_version: 1,
      producer: "message-service",
      occurred_at: response.created_at,
      correlation_id: correlation_id,
      actor_user_id: response.sender_user_id,
      payload: %{
        "conversation_id" => response.conversation_id,
        "message_id" => response.message_id,
        "sender_user_id" => response.sender_user_id,
        "message_type" => response.message_type,
        "status" => response.status,
        "created_at" => response.created_at,
        "media_id" => response.media_id,
        "metadata" => response.metadata
      }
    })
  end

  defp kafka_publish_enabled? do
    Application.get_env(:message_service, :kafka_publish_enabled, false) ||
      System.get_env("KAFKA_PUBLISH_ENABLED") in ["true", "1", "yes"]
  end

  defp update_message_in_store(attrs) do
    with {:ok, conversation_id} <- required_attr(attrs, "conversation_id"),
         {:ok, message_id} <- required_attr(attrs, "message_id"),
         {:ok, actor_user_id} <- required_attr(attrs, "actor_user_id"),
         {:ok, body} <- required_attr(attrs, "body"),
         edited_at = now(),
         bucket_date = get_attr(attrs, "bucket_date") || bucket_date(edited_at),
         :ok <- authorize_author(conversation_id, bucket_date, message_id, actor_user_id) do
      message_attrs = %{
        "conversation_id" => conversation_id,
        "bucket_date" => bucket_date,
        "message_id" => message_id,
        "body" => body,
        "status" => "edited",
        "edited_at" => edited_at
      }

      case MessageStore.update_message(message_attrs) do
        {:ok, message} -> {:ok, edited_message_response(message)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp delete_message_in_store(attrs) do
    with {:ok, conversation_id} <- required_attr(attrs, "conversation_id"),
         {:ok, message_id} <- required_attr(attrs, "message_id"),
         {:ok, actor_user_id} <- required_attr(attrs, "actor_user_id"),
         deleted_at = now(),
         bucket_date = get_attr(attrs, "bucket_date") || bucket_date(deleted_at),
         :ok <- authorize_author(conversation_id, bucket_date, message_id, actor_user_id) do
      message_attrs = %{
        "conversation_id" => conversation_id,
        "bucket_date" => bucket_date,
        "message_id" => message_id,
        "status" => "deleted",
        "deleted_at" => deleted_at
      }

      case MessageStore.delete_message(message_attrs) do
        {:ok, message} -> {:ok, deleted_message_response(message)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Author-only enforcement for edit/delete. Runs at this shared boundary so both
  # the HTTP (PATCH/DELETE) and realtime channel (message:update/message:delete)
  # paths inherit one check. Returns {:error, :message_forbidden} when the acting
  # user is not the original sender, or propagates store errors (not_found /
  # store_unavailable). Only reached on the DB-backed path; placeholder unaffected.
  defp authorize_author(conversation_id, bucket_date, message_id, actor_user_id) do
    fetch_attrs = %{
      "conversation_id" => conversation_id,
      "bucket_date" => bucket_date,
      "message_id" => message_id
    }

    case MessageStore.get_message(fetch_attrs) do
      {:ok, %{sender_user_id: ^actor_user_id}} -> :ok
      {:ok, _message} -> {:error, :message_forbidden}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_messages_from_store(attrs) do
    with {:ok, conversation_id} <- required_attr(attrs, "conversation_id") do
      created_at = now()

      attrs =
        attrs
        |> Map.put("conversation_id", conversation_id)
        |> Map.put_new("bucket_date", bucket_date(created_at))
        |> Map.put_new("limit", 50)

      case MessageStore.list_messages(attrs) do
        {:ok, timeline} ->
          {:ok, %{timeline | messages: Enum.map(timeline.messages, &message_response/1)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp placeholder_send_message(attrs) do
    {:ok,
     %{
       conversation_id: Map.get(attrs, "conversation_id", "conv_placeholder"),
       message_id: "msg_placeholder",
       sender_user_id: "user_placeholder",
       message_type: Map.get(attrs, "message_type", "text"),
       body: Map.get(attrs, "body"),
       status: "active",
       created_at: "2026-06-17T10:15:00Z"
     }}
  end

  defp placeholder_list_messages(attrs) do
    {:ok,
     %{
       conversation_id: Map.get(attrs, "conversation_id", "conv_placeholder"),
       messages: [
         %{
           message_id: "msg_placeholder",
           sender_user_id: "user_placeholder",
           message_type: "text",
           body: "Hello",
           status: "active",
           created_at: "2026-06-17T10:15:00Z"
         }
       ],
       next_cursor: nil
     }}
  end

  defp message_response(message) do
    %{
      conversation_id: message.conversation_id,
      message_id: message.message_id,
      sender_user_id: message.sender_user_id,
      message_type: message.message_type,
      body: message.body,
      media_id: message.media_id,
      caption: caption_from(message),
      reply_to_message_id: message.reply_to_message_id,
      status: message.status,
      metadata: message.metadata,
      created_at: iso8601(message.created_at),
      edited_at: iso8601(message.edited_at),
      deleted_at: iso8601(message.deleted_at),
      # Read-receipt aggregate surfaced on load so ticks survive reload (defaults to 0 on the
      # placeholder / non-persisted paths that don't carry receipts).
      read_by_count: Map.get(message, :read_by_count, 0),
      delivered_by_count: Map.get(message, :delivered_by_count, 0)
    }
  end

  defp edited_message_response(message) do
    %{
      conversation_id: message.conversation_id,
      message_id: message.message_id,
      body: message.body,
      status: message.status,
      edited_at: iso8601(message.edited_at)
    }
  end

  defp deleted_message_response(message) do
    %{
      conversation_id: message.conversation_id,
      message_id: message.message_id,
      deleted: true,
      status: message.status,
      deleted_at: iso8601(message.deleted_at)
    }
  end

  defp message_body(attrs, "text", _caption) do
    case get_attr(attrs, "body") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :message_invalid}
    end
  end

  defp message_body(attrs, "media", caption) do
    {:ok, get_attr(attrs, "body") || caption}
  end

  defp message_body(attrs, _message_type, _caption), do: {:ok, get_attr(attrs, "body")}

  defp media_id(attrs, "media"), do: required_attr(attrs, "media_id")
  defp media_id(attrs, _message_type), do: {:ok, get_attr(attrs, "media_id")}

  defp caption(attrs, "media") do
    case get_attr(attrs, "caption") do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, :message_invalid}
    end
  end

  defp caption(_attrs, _message_type), do: {:ok, nil}

  defp metadata(attrs, "media", media_id, caption) do
    with {:ok, base_metadata} <- metadata(attrs) do
      metadata =
        base_metadata
        |> Map.put("media_id", media_id)
        |> put_optional("caption", caption)
        |> merge_optional_media_metadata(attrs)

      {:ok, metadata}
    end
  end

  defp metadata(attrs, _message_type, _media_id, _caption), do: metadata(attrs)

  defp metadata(attrs) do
    case get_attr(attrs, "metadata") do
      nil -> {:ok, %{}}
      metadata when is_map(metadata) -> {:ok, stringify_metadata(metadata)}
      _ -> {:error, :message_invalid}
    end
  end

  defp merge_optional_media_metadata(metadata, attrs) do
    attrs
    |> optional_media_metadata()
    |> Map.merge(metadata, fn _key, _from_attrs, from_metadata -> from_metadata end)
  end

  defp optional_media_metadata(attrs) do
    ["object_key", "filename", "content_type", "size_bytes"]
    |> Enum.reduce(%{}, fn key, metadata ->
      case get_attr(attrs, key) do
        nil -> metadata
        "" -> metadata
        value when is_binary(value) -> Map.put(metadata, key, value)
        value when is_integer(value) and key == "size_bytes" -> Map.put(metadata, key, "#{value}")
        _value -> metadata
      end
    end)
  end

  defp stringify_metadata(metadata) do
    metadata
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      with key when is_binary(key) <- stringify_key(key),
           {:ok, value} <- stringify_value(value) do
        Map.put(acc, key, value)
      else
        _ -> acc
      end
    end)
  end

  defp stringify_key(key) when is_binary(key), do: key
  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(_key), do: nil

  defp stringify_value(value) when is_binary(value), do: {:ok, value}
  defp stringify_value(value) when is_integer(value), do: {:ok, "#{value}"}
  defp stringify_value(value) when is_float(value), do: {:ok, "#{value}"}
  defp stringify_value(value) when is_boolean(value), do: {:ok, "#{value}"}
  defp stringify_value(nil), do: :error
  defp stringify_value(_value), do: :error

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, ""), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp caption_from(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "caption") || Map.get(metadata, :caption)
  end

  defp caption_from(_message), do: nil

  defp required_attr(attrs, key) do
    case get_attr(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :message_invalid}
    end
  end

  defp get_attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp bucket_date(%DateTime{} = datetime),
    do: datetime |> DateTime.to_date() |> Date.to_iso8601()

  defp generate_timeuuid do
    gregorian_epoch_offset = 0x01B21DD213814000
    timestamp = System.os_time(:nanosecond) |> div(100) |> Kernel.+(gregorian_epoch_offset)

    time_low = Bitwise.band(timestamp, 0xFFFF_FFFF)
    time_mid = Bitwise.band(Bitwise.bsr(timestamp, 32), 0xFFFF)
    time_hi = Bitwise.band(Bitwise.bsr(timestamp, 48), 0x0FFF) |> Bitwise.bor(0x1000)

    <<clock_seq::16, node::48>> = :crypto.strong_rand_bytes(8)
    clock_seq = Bitwise.band(clock_seq, 0x3FFF) |> Bitwise.bor(0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [
      time_low,
      time_mid,
      time_hi,
      clock_seq,
      node
    ])
    |> IO.iodata_to_binary()
    |> String.downcase()
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(value), do: value
end
