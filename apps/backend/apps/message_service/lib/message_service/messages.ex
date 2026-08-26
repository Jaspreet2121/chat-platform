defmodule MessageService.Messages do
  @moduledoc """
  Message creation, edit, and delete boundary.

  DB-backed create/list behavior is feature-gated. Live ScyllaDB writes,
  sender ownership enforcement, and rate limits are future work. `message.created.v1`
  is published fire-and-forget after a successful create when Kafka publishing is enabled.
  """

  require Logger

  alias MessageService.MessageStore

  # Bounded so the value is a SIGNAL, not a tracking number. Client display: >=1 "Forwarded",
  # >=5 "Forwarded many times".
  @forward_depth_cap 5
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
    cond do
      # BLOCK DROP: a DIRECT message whose recipient has blocked the sender. Return a well-formed canonical
      # message to the SENDER (single tick) but persist and publish NOTHING — the message never exists
      # server-side, so the blocker can never receive it via ANY path (socket fan-out, timeline read, reconnect
      # catch-up, or push). The `delivery_disposition => "drop"` flag is set SERVER-SIDE by the send gate
      # (ConversationService.Participants.authorize_send); a client can at most drop its own message. WhatsApp
      # semantics: the sender sees "sent" and learns nothing.
      get_attr(attrs, "delivery_disposition") == "drop" ->
        synthesize_dropped(attrs)

      message_persistence_enabled?() ->
        create_message_in_store(attrs)

      true ->
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

  @doc """
  Message info — per-user delivery/read state, SENDER-only (the store enforces sender + tombstone; the
  gateway enforces session + membership). Placeholder path: empty lists (nothing persisted to report).
  """
  def message_info(attrs) do
    if message_persistence_enabled?() do
      MessageService.MessageStore.message_info(attrs)
    else
      {:ok,
       %{
         conversation_id: Map.get(attrs, "conversation_id"),
         message_id: Map.get(attrs, "message_id"),
         read: [],
         delivered: [],
         read_hidden: false
       }}
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

  @doc """
  Admin soft-delete of ANY message — bypasses the sender-only `authorize_author` check (the caller is
  a verified platform admin, gated upstream by the gateway's RequireAdmin). Still a soft-delete
  (status='deleted'), never a hard row delete. Looks the message up by id to resolve its conversation.
  """
  def admin_delete_message(attrs) do
    if message_persistence_enabled?() do
      with {:ok, message_id} <- required_attr(attrs, "message_id"),
           {:ok, message} <-
             MessageStore.get_message(%{
               "message_id" => message_id,
               "conversation_id" => get_attr(attrs, "conversation_id"),
               "bucket_date" => get_attr(attrs, "bucket_date")
             }) do
        deleted_at = now()

        case MessageStore.delete_message(%{
               "conversation_id" => message.conversation_id,
               "bucket_date" => get_attr(attrs, "bucket_date") || bucket_date(deleted_at),
               "message_id" => message_id,
               "status" => "deleted",
               "deleted_at" => deleted_at
             }) do
          {:ok, deleted} -> {:ok, deleted_message_response(deleted)}
          {:error, reason} -> {:error, reason}
        end
      end
    else
      {:error, :message_store_unavailable}
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

  # --- FORWARD DEPTH (misinformation friction, not a statistic) -----------------------------------

  # WhatsApp's "Forwarded many times" is friction, not a count of copies. That framing is the design:
  # what matters is DISTANCE from the origin, and a bounded hop depth measures that honestly. A true
  # lineage count needs a graph or a contended counter on a root message, and it would answer a
  # different question (how many copies exist) than the one the badge asks.
  #
  # SERVER-COMPUTED, NEVER CLIENT-ASSERTED. Any `forward_depth` a client puts in metadata is DISCARDED
  # before this runs. A friction signal a client can reset to 0 is worthless, and the client that most
  # wants to reset it is the one spreading the message.
  #
  # Depth is read from the SOURCE MESSAGE ROW, which is why the client sends
  # `forwarded_from_message_id`. It rides the MESSAGE, not the media — so it survives Android
  # re-uploading media on forward (a new media_id, a new message, but the client still knows which
  # message it forwarded).
  #
  # An untraceable source (unknown id, deleted, a conversation the forwarder has since left) yields
  # depth 1, not an error: a forward we cannot trace is still a forward, and failing the send would be
  # a far worse outcome than a slightly low badge.
  #
  # HONEST LIMITATION, also stated in the contract: depth undercounts BREADTH. A message blasted
  # directly to 100 chats is depth 1 for every recipient. WhatsApp has the same property; the signal
  # is meant to flag content that has travelled FAR from its source, not content sent widely once.
  defp apply_forward_depth(metadata, attrs) do
    # Strip first, unconditionally — this is what makes the value non-forgeable.
    metadata = Map.delete(metadata, "forward_depth")

    case get_attr(attrs, "forwarded_from_message_id") do
      source_id when is_binary(source_id) and source_id != "" ->
        depth = min(source_forward_depth(attrs, source_id) + 1, @forward_depth_cap)
        Map.put(metadata, "forward_depth", depth)

      _ ->
        metadata
    end
  end

  defp source_forward_depth(attrs, source_id) do
    conversation_id =
      get_attr(attrs, "forwarded_from_conversation_id") || get_attr(attrs, "conversation_id")

    case MessageStore.get_message(%{
           "conversation_id" => conversation_id,
           "message_id" => source_id
         }) do
      {:ok, message} -> depth_of(message)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  # Clamped on READ as well as on write: a row written before the cap existed, or by a path that
  # somehow stored a larger value, must not produce an out-of-range badge.
  defp depth_of(message) do
    metadata = Map.get(message, :metadata) || Map.get(message, "metadata") || %{}

    case Map.get(metadata, "forward_depth") || Map.get(metadata, :forward_depth) do
      n when is_integer(n) and n > 0 -> min(n, @forward_depth_cap)
      _ -> 0
    end
  end

  defp create_message_in_store(attrs) do
    with {:ok, conversation_id} <- required_attr(attrs, "conversation_id"),
         {:ok, sender_user_id} <- required_attr(attrs, "sender_user_id"),
         {:ok, message_type} <- required_attr(attrs, "message_type"),
         :ok <- check_secret_policy(conversation_id, message_type, attrs),
         {:ok, client_msg_id} <- client_msg_id(attrs),
         {:ok, media_id} <- media_id(attrs, message_type),
         {:ok, caption} <- caption(attrs, message_type),
         {:ok, body} <- message_body(attrs, message_type, caption),
         {:ok, metadata} <- metadata(attrs, message_type, media_id, caption) do
      created_at = now()

      with {:ok, metadata} <- decorate_metadata(metadata, attrs, created_at) do
        # IDEMPOTENT SEND (107): with a client_msg_id, claim-before-create in the Postgres ledger —
        # a duplicate returns the FIRST write's message as a SUCCESS and touches nothing downstream
        # (no store write, no outbox staging, no publish — those all live below this branch).
        # Without one, byte-identical to the pre-107 path.
        case claim_client_msg(conversation_id, sender_user_id, client_msg_id) do
          {:existing, message} ->
            {:ok, message_response(message)}

          {:new, message_id} ->
            message_attrs = %{
              "conversation_id" => conversation_id,
              "bucket_date" => bucket_date(created_at),
              "message_id" => message_id,
              "sender_user_id" => sender_user_id,
              "message_type" => message_type,
              "body" => body,
              "media_id" => media_id,
              "reply_to_message_id" => get_attr(attrs, "reply_to_message_id"),
              "status" => "active",
              "metadata" => apply_forward_depth(metadata, attrs),
              "created_at" => created_at,
              "edited_at" => nil,
              "deleted_at" => nil
            }

            case MessageStore.put_message(message_attrs) do
              {:ok, message} ->
                response = message_response(message) |> with_fresh_poll(message_type, metadata)
                publish_message_created(response)
                {:ok, response}

              {:error, reason} ->
                {:error, reason}
            end
        end
      end
    end
  end

  # ---- offline foundation (107) -----------------------------------------------------------------

  defp client_msg_id(attrs) do
    case get_attr(attrs, "client_msg_id") do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case Ecto.UUID.cast(value) do
          {:ok, normalized} -> {:ok, normalized}
          :error -> {:error, :message_invalid}
        end

      _ ->
        {:error, :message_invalid}
    end
  end

  # composed_at (client compose time, CLAMPED to [now-7d, now]) is surfaced in metadata for display
  # ONLY. SERVER ORDERING STAYS BY SERVER RECEIPT — the message_id is the server-minted timeuuid and
  # Scylla clusters by it; history is NEVER reordered by client clocks (a device with a wrong clock,
  # or a week-old offline backlog syncing in, must not rewrite everyone's timeline). The offline
  # delivery hint becomes the {"offline": true} metadata marker (the existing content-kind
  # convention) — everything downstream sees a perfectly normal message.
  defp decorate_metadata(metadata, attrs, created_at) do
    with {:ok, metadata} <-
           apply_composed_at(metadata, get_attr(attrs, "composed_at"), created_at) do
      if get_attr(attrs, "delivery_hint") == "nearby_sync" do
        {:ok, Map.put(metadata, "offline", true)}
      else
        {:ok, metadata}
      end
    end
  end

  defp apply_composed_at(metadata, nil, _created_at), do: {:ok, metadata}

  defp apply_composed_at(metadata, value, created_at) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, composed, _offset} ->
        {:ok,
         Map.put(
           metadata,
           "composed_at",
           composed |> clamp_composed_at(created_at) |> DateTime.to_iso8601()
         )}

      _ ->
        {:error, :message_invalid}
    end
  end

  defp apply_composed_at(_metadata, _value, _created_at), do: {:error, :message_invalid}

  @doc false
  # Public (doc false) for the pure boundary tests: clamp into [now - 7d, now].
  def clamp_composed_at(%DateTime{} = composed, %DateTime{} = now) do
    floor = DateTime.add(now, -7 * 86_400, :second)

    cond do
      DateTime.compare(composed, floor) == :lt -> floor
      DateTime.compare(composed, now) == :gt -> now
      true -> composed
    end
  end

  # ---- secret chats (108) -----------------------------------------------------------------------

  @sealed_types ["sealed", "system"]
  @sealed_max_bytes 64 * 1024

  # In a SECRET conversation only sealed (+ plaintext-free system) messages are accepted — the
  # plaintext rejection is defense against a buggy/old client leaking content into a chat both
  # sides believe is E2EE. Sealed outside a secret conversation is equally rejected. System
  # messages in a secret chat stay plaintext BY DESIGN: they carry protocol state (encryption
  # enabled / keys changed), never user content.
  defp check_secret_policy(conversation_id, message_type, attrs) do
    secret? = conversation_secret?(conversation_id)

    cond do
      secret? and message_type not in @sealed_types ->
        {:error, :secret_plaintext_rejected}

      not secret? and message_type == "sealed" ->
        {:error, :secret_sealed_rejected}

      message_type == "sealed" ->
        validate_sealed(conversation_id, attrs)

      true ->
        :ok
    end
  end

  defp conversation_secret?(conversation_id) do
    case MessageService.Repo.query(
           "SELECT secret FROM conversations WHERE id = $1::text::uuid",
           [conversation_id]
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp validate_sealed(conversation_id, attrs) do
    sealed = get_attr(attrs, "sealed")

    with true <- is_binary(get_attr(attrs, "client_msg_id")) || {:error, :secret_sealed_invalid},
         true <- is_map(sealed) || {:error, :secret_sealed_invalid},
         true <- Map.get(sealed, "v") == 1 || {:error, :secret_sealed_invalid},
         true <- nonempty?(Map.get(sealed, "alg")) || {:error, :secret_sealed_invalid},
         true <-
           nonempty?(Map.get(sealed, "sender_device_id")) || {:error, :secret_sealed_invalid},
         true <- nonempty?(Map.get(sealed, "sig_b64")) || {:error, :secret_sealed_invalid},
         true <-
           valid_recipients?(Map.get(sealed, "recipients")) || {:error, :secret_sealed_invalid},
         true <-
           byte_size(Jason.encode!(sealed)) <= @sealed_max_bytes ||
             {:error, :secret_sealed_invalid},
         true <-
           recipients_are_member_devices?(conversation_id, Map.get(sealed, "recipients")) ||
             {:error, :secret_sealed_invalid} do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp nonempty?(value), do: is_binary(value) and value != ""

  defp valid_recipients?(recipients) do
    is_list(recipients) and recipients != [] and
      Enum.all?(recipients, fn recipient ->
        is_map(recipient) and nonempty?(Map.get(recipient, "device_id")) and
          nonempty?(Map.get(recipient, "envelope_b64"))
      end)
  end

  # Every recipient device must be a LIVE device of one of the conversation's members — a foreign
  # device_id in the envelope list is either a bug or an exfiltration attempt; both are refused.
  defp recipients_are_member_devices?(conversation_id, recipients) do
    %{rows: rows} =
      MessageService.Repo.query!(
        "SELECT ds.device_id FROM conversation_participants p " <>
          "JOIN device_sessions ds ON ds.user_id = p.user_id AND ds.revoked_at IS NULL " <>
          "WHERE p.conversation_id = $1::text::uuid AND p.left_at IS NULL",
        [conversation_id]
      )

    allowed = MapSet.new(rows, fn [device_id] -> device_id end)
    Enum.all?(recipients, &MapSet.member?(allowed, Map.get(&1, "device_id")))
  rescue
    _ -> false
  end

  # nil client id → a fresh server timeuuid, exactly the pre-107 behaviour.
  defp claim_client_msg(_conversation_id, _sender_user_id, nil), do: {:new, generate_timeuuid()}

  defp claim_client_msg(conversation_id, sender_user_id, client_msg_id) do
    app_id =
      MessageService.WebhookEvents.conversation_app_id(conversation_id) ||
        SharedInfra.Tenancy.default_app_id()

    fresh_id = generate_timeuuid()

    {:ok, outcome} =
      MessageService.Repo.transaction(fn ->
        # Serializes only this (conversation, sender, client id) tuple — the claim precedent.
        MessageService.Repo.query!(
          "SELECT pg_advisory_xact_lock(hashtextextended($1 || ':' || $2 || ':' || $3, 0))",
          [conversation_id, sender_user_id, client_msg_id]
        )

        # Opportunistic 30d sweep (indexed range; the ledger is dedup state, not history).
        MessageService.Repo.query!(
          "DELETE FROM message_client_ids WHERE created_at < now() - interval '30 days'",
          []
        )

        %{rows: rows} =
          MessageService.Repo.query!(
            "SELECT message_id::text FROM message_client_ids " <>
              "WHERE app_id = $1::text::uuid AND conversation_id = $2::text::uuid " <>
              "AND sender_user_id = $3::text::uuid AND client_msg_id = $4::text::uuid",
            [app_id, conversation_id, sender_user_id, client_msg_id]
          )

        case rows do
          [[existing_id]] ->
            # A claim whose message never landed (a crashed create) self-heals: re-point the claim
            # at a fresh id and create anew — still under the lock, so concurrent retries serialize.
            case MessageStore.get_message(%{
                   "conversation_id" => conversation_id,
                   "message_id" => existing_id
                 }) do
              {:ok, message} ->
                {:existing, message}

              _ ->
                MessageService.Repo.query!(
                  "UPDATE message_client_ids SET message_id = $5::text::uuid, created_at = now() " <>
                    "WHERE app_id = $1::text::uuid AND conversation_id = $2::text::uuid " <>
                    "AND sender_user_id = $3::text::uuid AND client_msg_id = $4::text::uuid",
                  [app_id, conversation_id, sender_user_id, client_msg_id, fresh_id]
                )

                {:new, fresh_id}
            end

          [] ->
            MessageService.Repo.query!(
              "INSERT INTO message_client_ids " <>
                "(app_id, conversation_id, sender_user_id, client_msg_id, message_id) " <>
                "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, $4::text::uuid, $5::text::uuid)",
              [app_id, conversation_id, sender_user_id, client_msg_id, fresh_id]
            )

            {:new, fresh_id}
        end
      end)

    outcome
  end

  # The block-drop ack: a CANONICAL message (byte-identical shape to a real create's message_response, per
  # Android contract §4.1 — message_id, created_at, status, receipt/reaction aggregates, all of it) that the
  # sender's outbox replaces its PENDING row from, WITHOUT persisting or publishing. A partial ack would leave
  # the outbox stuck PENDING, which itself reveals the block. The message_id is a real timeuuid from the SAME
  # generator a real create uses — well-formed and unique — there is simply no row behind it. Runs regardless
  # of message_persistence (it never touches the store).
  defp synthesize_dropped(attrs) do
    with {:ok, conversation_id} <- required_attr(attrs, "conversation_id"),
         {:ok, sender_user_id} <- required_attr(attrs, "sender_user_id"),
         {:ok, message_type} <- required_attr(attrs, "message_type"),
         {:ok, media_id} <- media_id(attrs, message_type),
         {:ok, caption} <- caption(attrs, message_type),
         {:ok, body} <- message_body(attrs, message_type, caption),
         {:ok, metadata} <- metadata(attrs, message_type, media_id, caption) do
      message = %{
        conversation_id: conversation_id,
        message_id: generate_timeuuid(),
        sender_user_id: sender_user_id,
        message_type: message_type,
        body: body,
        media_id: media_id,
        reply_to_message_id: get_attr(attrs, "reply_to_message_id"),
        status: "active",
        metadata: metadata,
        created_at: now(),
        edited_at: nil,
        deleted_at: nil
      }

      {:ok, message_response(message)}
    end
  end

  # Fire-and-forget event publish. This MUST NOT affect message creation: the
  # {:ok, response} above is computed and returned independently, and any envelope
  # error, producer error, exception, or exit here is caught and logged — never
  # propagated. Disabled by default (KAFKA_PUBLISH_ENABLED); the default producer
  # adapter is the non-connecting NoopProducer, so nothing connects.
  # Mirrors publish_message_created/1 exactly — unlinked Task, correlation id captured in the CALLER
  # process, every failure logged and swallowed. A delete must never fail because a broker is down.
  defp publish_message_deleted(response) do
    # Same ownership rule as publish_message_created/1 above.
    if kafka_publish_enabled?() and not MessageService.EventOutbox.owns_publishes?() do
      correlation_id = SharedInfra.Correlation.get_or_generate()
      Task.start(fn -> do_publish_message_deleted(response, correlation_id) end)
    end

    :ok
  end

  defp do_publish_message_deleted(response, correlation_id) do
    envelope =
      Envelope.build(%{
        event_id: Ecto.UUID.generate(),
        event_type: "message.deleted.v1",
        event_version: 1,
        producer: "message-service",
        occurred_at: response.deleted_at || DateTime.utc_now(),
        correlation_id: correlation_id,
        actor_user_id: response.sender_user_id,
        # THIN, like message.created: ids only. There is deliberately no body here — a delete event
        # carrying the deleted text would be the copy this whole design avoids.
        payload: %{
          "conversation_id" => response.conversation_id,
          "message_id" => response.message_id,
          "sender_user_id" => response.sender_user_id,
          "deleted_at" => response.deleted_at
        }
      })

    case envelope do
      {:ok, built} ->
        # SAME KEY as message.created — conversation_id — so a create and its delete land on one
        # partition and are consumed in order. Any other key would let a delete overtake its create.
        case Producer.produce(@message_topic, response.conversation_id, built) do
          {:ok, _} -> :ok
          {:error, reason} -> Logger.warning("message.deleted publish failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("message.deleted envelope invalid, skipping publish: #{inspect(reason)}")
    end
  rescue
    error -> Logger.error("message.deleted publish raised, ignored: #{inspect(error)}")
  catch
    kind, value -> Logger.error("message.deleted publish #{kind}, ignored: #{inspect(value)}")
  end

  defp publish_message_created(response) do
    # Under the Scylla adapter the EVENT OUTBOX owns this publish (staged in the store's joined
    # transaction, broker-acked, relay-backed) — firing here too would double-publish every create
    # as the NORM rather than as a recovery artifact. Other adapters keep this legacy
    # fire-and-forget path, with its known loss window, stated in EventOutbox's moduledoc.
    if kafka_publish_enabled?() and not MessageService.EventOutbox.owns_publishes?() do
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
        # Surface a produce failure (e.g. NoopProducer's {:error, :kafka_unavailable}, or a real
        # broker error) instead of silently discarding it — a swallowed error here masked the
        # baked-NoopProducer trap in prod. Still fire-and-forget: this runs in an unlinked Task.
        case Producer.produce(@message_topic, response.conversation_id, envelope) do
          {:ok, _} -> :ok
          {:error, reason} -> Logger.warning("message.created publish failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("message.created envelope invalid, skipping publish: #{inspect(reason)}")
    end
  rescue
    error -> Logger.error("message.created publish raised, ignored: #{inspect(error)}")
  catch
    kind, value -> Logger.error("message.created publish #{kind}, ignored: #{inspect(value)}")
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
         {:ok, mode} <- update_mode(attrs),
         updated_at = now(),
         bucket_date = get_attr(attrs, "bucket_date") || bucket_date(updated_at),
         {:ok, existing} <-
           fetch_own_message(conversation_id, bucket_date, message_id, actor_user_id) do
      apply_message_update(
        mode,
        attrs,
        existing,
        conversation_id,
        bucket_date,
        message_id,
        updated_at
      )
    end
  end

  # Decide the update shape BEFORE fetching (so a payload with neither a metadata patch nor a body is
  # rejected as invalid up front, matching the original edit validation): a non-empty metadata_patch is
  # a live-location update; a non-empty body is an edit; otherwise invalid.
  defp update_mode(attrs) do
    patch = get_attr(attrs, "metadata_patch")
    body = get_attr(attrs, "body")

    cond do
      is_map(patch) and map_size(patch) > 0 -> {:ok, :metadata}
      is_binary(body) and body != "" -> {:ok, :body}
      true -> {:error, :message_invalid}
    end
  end

  # Live-location: a metadata PATCH (latest position / live flag). Merges into the message's existing
  # metadata and leaves body/status/edited_at intact (it is not an "edit"). Author-gated above.
  defp apply_message_update(
         :metadata,
         attrs,
         existing,
         conversation_id,
         bucket_date,
         message_id,
         _updated_at
       ) do
    merged =
      Map.merge(existing.metadata || %{}, stringify_metadata(get_attr(attrs, "metadata_patch")))

    message_attrs = %{
      "conversation_id" => conversation_id,
      "bucket_date" => bucket_date,
      "message_id" => message_id,
      "metadata" => merged
    }

    case MessageStore.update_message(message_attrs) do
      {:ok, message} -> {:ok, message_response(message)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Body edit (existing behavior): marks the message "edited".
  defp apply_message_update(
         :body,
         attrs,
         _existing,
         conversation_id,
         bucket_date,
         message_id,
         updated_at
       ) do
    message_attrs = %{
      "conversation_id" => conversation_id,
      "bucket_date" => bucket_date,
      "message_id" => message_id,
      "body" => get_attr(attrs, "body"),
      "status" => "edited",
      "edited_at" => updated_at
    }

    case MessageStore.update_message(message_attrs) do
      {:ok, message} -> {:ok, edited_message_response(message)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Author-only: fetch the message and confirm the caller is its sender (returns the row so callers can
  # merge onto its existing metadata). Mirrors authorize_author/4 but yields the message.
  defp fetch_own_message(conversation_id, bucket_date, message_id, actor_user_id) do
    fetch_attrs = %{
      "conversation_id" => conversation_id,
      "bucket_date" => bucket_date,
      "message_id" => message_id
    }

    case MessageStore.get_message(fetch_attrs) do
      {:ok, %{sender_user_id: ^actor_user_id} = message} ->
        # AUTHOR CONFIRMED — now refuse a soft-deleted message. A body edit sets status="edited" +
        # edited_at, which would RESURRECT the tombstone (there is no un-delete flow; the only place
        # deleted_at is cleared is a fresh insert). This gate covers BOTH update modes (:body edits and
        # :metadata / live-location patches) because it is the single gate on update_message_in_store —
        # a deleted message accepts no update of any kind.
        if soft_deleted?(message), do: {:error, :message_deleted}, else: {:ok, message}

      # Checked BEFORE the deleted state on purpose: a NON-author must not be able to distinguish
      # "deleted" from "not yours" (the socket surfaces those as different errors). They always get
      # :message_forbidden; only the author ever learns the message is deleted.
      {:ok, _message} ->
        {:error, :message_forbidden}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `deleted_at` is the AUTHORITATIVE marker: only the delete path sets it, and — unlike `status` — it
  # SURVIVES a body edit (which overwrites status with "edited" but never clears deleted_at). So this also
  # refuses further edits to any row already resurrected by this bug before the fix. `status` is checked too,
  # belt-and-braces, in case a store variant sets one without the other.
  defp soft_deleted?(message) do
    Map.get(message, :deleted_at) != nil or Map.get(message, :status) == "deleted"
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
        {:ok, message} ->
          # A deleted message must stop occupying pin budget (092). The pin READ already filters
          # status='deleted', so this is about the CAP, not about hiding the tombstone — which is why
          # it is best-effort and never fails the delete.
          MessageService.Pins.unpin_deleted(message_id)

          # NET-NEW EVENT (message.deleted.v1). Required, not optional: the inbox preview is
          # maintained from this topic once messages live in Scylla, and a preview fed by creates
          # alone keeps showing a deleted message's TEXT in the chat list forever. That is deleted
          # content on screen, not a stale counter. Same fire-and-forget shape as the create publish.
          publish_message_deleted(deleted_message_response(message))

          {:ok, deleted_message_response(message)}

        {:error, reason} ->
          {:error, reason}
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

  @doc """
  Normalizes a store-shaped message map into the public response shape (ISO timestamps + the per-viewer
  aggregates). Public so the Starred (`MessageService.Stars`) and Search (`MessageService.Search`)
  list paths reuse the exact same shape as the timeline.
  """
  def message_response(message) do
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
      delivered_by_count: Map.get(message, :delivered_by_count, 0),
      # Reaction aggregate (emoji → count) + the viewer's own reaction, surfaced on load like receipts.
      reactions: Map.get(message, :reactions, []),
      my_reaction: Map.get(message, :my_reaction),
      # Whether the calling viewer has starred this message (drives the filled star on load).
      is_starred: Map.get(message, :is_starred, false),
      # Poll aggregate (question/options with counts + capped voter_ids/total_voters) — merged by the
      # list path for poll messages, nil otherwise. Computed from poll_votes at fetch time, ALWAYS.
      poll: Map.get(message, :poll)
    }
  end

  # A fresh poll's ack carries the ZERO aggregate (no votes yet — no query needed), so the sender's
  # outbox row renders the poll immediately.
  defp with_fresh_poll(response, "poll", %{"poll" => definition}),
    do: Map.put(response, :poll, MessageService.Polls.zero_aggregate(definition))

  defp with_fresh_poll(response, _message_type, _metadata), do: response

  defp edited_message_response(message) do
    %{
      conversation_id: message.conversation_id,
      message_id: message.message_id,
      body: message.body,
      status: message.status,
      edited_at: iso8601(message.edited_at)
    }
  end

  # `sender_user_id` is part of the contract, not an addition for one consumer: a delete response that
  # cannot identify whose message was deleted is incomplete on its own terms. Its absence made
  # message.deleted raise KeyError inside the publisher's rescue, so the event NEVER fired and the
  # failure sat in a warning — the privacy fix that event exists for did not work end to end.
  defp deleted_message_response(message) do
    %{
      conversation_id: message.conversation_id,
      message_id: message.message_id,
      sender_user_id: Map.get(message, :sender_user_id),
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

  # A poll's body IS the question (validated) — any client that doesn't understand message_type "poll"
  # (older builds, /v1 SDK consumers) degrades to showing the question as plain text.
  defp message_body(attrs, "poll", _caption) do
    with {:ok, definition} <- poll_definition(attrs) do
      {:ok, definition["question"]}
    end
  end

  # Sealed messages carry NO plaintext body — content lives only in metadata.sealed (ciphertext).
  defp message_body(_attrs, "sealed", _caption), do: {:ok, nil}
  defp message_body(attrs, _message_type, _caption), do: {:ok, get_attr(attrs, "body")}

  defp media_id(attrs, "media"), do: required_attr(attrs, "media_id")
  # SEALED (108/110): the attachment's media_id rides INSIDE the encrypted envelope, never as a
  # top-level attr — forcing nil here guarantees the gallery/link projections (driven by a top-level
  # media_id) never fire for a sealed message, whatever the client sends.
  defp media_id(_attrs, "sealed"), do: {:ok, nil}
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

  # Poll metadata is SERVER-REBUILT: exactly {"poll" => {question, allows_multiple, options[{id,text}]}}
  # with server-generated stable option ids — client extras are discarded, malformed polls are rejected
  # with a specific code (never stored broken). Votes live in poll_votes; this is the immutable definition.
  defp metadata(attrs, "poll", _media_id, _caption) do
    with {:ok, definition} <- poll_definition(attrs) do
      {:ok, %{"poll" => definition}}
    end
  end

  # The sealed envelope, stored OPAQUELY (shape/device validation happened in check_secret_policy;
  # the server never parses recipients[].envelope_b64).
  defp metadata(attrs, "sealed", _media_id, _caption),
    do: {:ok, %{"sealed" => get_attr(attrs, "sealed")}}

  defp metadata(attrs, _message_type, _media_id, _caption), do: metadata(attrs)

  # The client-supplied poll definition (metadata.poll), validated + normalized by MessageService.Polls.
  defp poll_definition(attrs) do
    case get_attr(attrs, "metadata") do
      %{} = metadata ->
        MessageService.Polls.normalize_definition(
          Map.get(metadata, "poll") || Map.get(metadata, :poll) || %{}
        )

      _ ->
        {:error, :poll_invalid_question}
    end
  end

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
