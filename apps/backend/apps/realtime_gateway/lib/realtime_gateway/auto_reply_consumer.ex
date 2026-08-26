defmodule RealtimeGateway.AutoReplyConsumer do
  @moduledoc """
  The auto-reply ENGINE's transport (102): a `brod_group_subscriber_v2` on `message.events.v1` —
  the same durable event stream the inbox/search/notification consumers ride (fed by the 096
  outbox), which is what makes this async BY CONSTRUCTION: the send path finished long before this
  group ever sees the event, and nothing here can block, fail, or slow an inbound message.

  Lives in the GATEWAY release deliberately: the reply must be a REAL message through
  `MessageClient.create_message` (so Scylla, search, unread counts, FCM and webhooks all fire from
  the pipeline itself) PLUS the live-socket `message_created` fan-out — and the Phoenix endpoint
  that owns those topics exists only here (the missed-call pill precedent).

  Best-effort like the notification consumers: EVERY message commits (a redelivered event is made
  harmless by the claim ledger, `UserService.AutoReplies.claim/1`, which is checked BEFORE sending —
  at-least-once delivery can at worst skip a reply, never duplicate one). Any raise is caught,
  logged, and committed: an engine bug must never wedge the partition or touch message flow.

  Enabled by `AUTO_REPLY_CONSUMER_ENABLED` (default OFF — the per-user settings are additionally
  disabled by default, so the feature is doubly invisible until turned on).
  """

  @behaviour :brod_group_subscriber_v2

  require Logger
  require Record

  alias RealtimeGateway.AutoReply

  Record.defrecordp(
    :kafka_message,
    Record.extract(:kafka_message, from_lib: "kafka_protocol/include/kpro_public.hrl")
  )

  @impl true
  def init(_init_info, init_data), do: {:ok, init_data}

  @impl true
  def handle_message(message, state) do
    message |> kafka_message(:value) |> handle_value()
    {:ok, :commit, state}
  end

  @doc false
  # Public so tests drive the full evaluate-claim-send path without Kafka plumbing.
  def handle_value(value) do
    case Jason.decode(value) do
      {:ok, %{"type" => "message.created"} = event} -> evaluate(event)
      _ -> :ok
    end
  rescue
    # ASYNC ISOLATION: whatever blew up, the original message was already delivered — log loudly,
    # commit, move on. (Mutation-proven: removing this rescue reddens the isolation test.)
    error ->
      Logger.error(
        "[auto_reply] evaluation crashed (event skipped): " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

  defp evaluate(event) do
    conversation_id = event["conversation_id"]
    sender_id = event["sender_user_id"]
    message_id = event["message_id"]

    with true <- is_binary(conversation_id) and is_binary(sender_id) and is_binary(message_id),
         {:ok, message} <-
           SharedInfra.MessageClient.get_message(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id
           }),
         {:ok, conversation} <-
           SharedInfra.ConversationClient.get_conversation(%{
             "conversation_id" => conversation_id,
             "user_id" => sender_id
           }),
         recipient_id when is_binary(recipient_id) <- direct_peer(conversation, sender_id),
         {:ok, settings} <-
           SharedInfra.UserClient.get_auto_replies(%{"user_id" => recipient_id}) do
      context = %{
        conversation_type: mget(conversation, :type),
        # SECRET CHATS (108): EXPLICIT boolean (the falsy-mget trap) — the engine must skip.
        conversation_secret?: conversation_secret_flag(conversation),
        sender_id: sender_id,
        recipient_id: recipient_id,
        sender_auto?: auto_message?(message),
        blocked?: blocked?(sender_id, recipient_id),
        settings: %{
          away: mget(settings, :away) || %{},
          greeting: mget(settings, :greeting) || %{}
        },
        contact?: contact?(recipient_id, sender_id),
        last_activity_at: last_activity_before(conversation, message),
        now: DateTime.utc_now()
      }

      case AutoReply.decide(context) do
        {:send, kind} -> claim_and_send(kind, context, conversation_id)
        :skip -> :ok
      end
    else
      _ -> :ok
    end
  end

  # CLAIM BEFORE SEND: a redelivered event that already claimed is :throttled here and sends
  # nothing; a claim that then fails to send self-heals next window (a missed auto-reply beats a
  # duplicated one).
  defp claim_and_send(kind, context, conversation_id) do
    window = AutoReply.claim_window_seconds(kind, context.settings)

    case SharedInfra.UserClient.claim_auto_reply(%{
           "user_id" => context.recipient_id,
           "app_id" => conversation_app(conversation_id),
           "conversation_id" => conversation_id,
           "kind" => to_string(kind),
           "window_seconds" => window
         }) do
      {:ok, outcome} ->
        if mget_atomish(outcome) == "claimed", do: send_reply(kind, context, conversation_id)
        :ok

      other ->
        Logger.warning("[auto_reply] claim failed (no reply sent): #{inspect(other)}")
        :ok
    end
  end

  defp send_reply(kind, context, conversation_id) do
    block = if kind == :greeting, do: context.settings.greeting, else: context.settings.away

    attrs = %{
      "conversation_id" => conversation_id,
      "sender_user_id" => context.recipient_id,
      "message_type" => "text",
      "body" => Map.get(block, "body"),
      # The same metadata convention every non-plain kind uses (call pills etc.) — and the
      # loop-proof: decide/1 skips any inbound message carrying this flag.
      "metadata" => %{"auto" => true, "auto_kind" => to_string(kind)}
    }

    case SharedInfra.MessageClient.create_message(attrs) do
      {:ok, response} ->
        endpoint = Application.get_env(:realtime_gateway, :endpoint, ApiGatewayWeb.Endpoint)
        endpoint.broadcast("conversation:" <> conversation_id, "message_created", response)
        endpoint.broadcast("user:" <> context.sender_id, "message_created", response)
        endpoint.broadcast("user:" <> context.recipient_id, "message_created", response)

        Logger.info(
          "[auto_reply] sent #{kind} for user=#{context.recipient_id} conv=#{conversation_id}"
        )

        :ok

      other ->
        Logger.warning("[auto_reply] send failed for #{kind}: #{inspect(other)}")
        :ok
    end
  end

  # The OTHER active participant of a direct conversation (nil for groups/malformed → skip).
  defp direct_peer(conversation, sender_id) do
    if mget(conversation, :type) == "direct" do
      (mget(conversation, :participants) || [])
      |> Enum.map(&mget(&1, :user_id))
      |> Enum.find(&(is_binary(&1) and &1 != sender_id))
    end
  end

  defp auto_message?(message) do
    metadata = mget(message, :metadata) || %{}
    Map.get(metadata, "auto") == true or Map.get(metadata, :auto) == true
  end

  # Fail CLOSED on a block-check error — a broken check must not cause a reply to a blocked party.
  # Explicit matches, NOT mget: `false` is a legal value and the `||` fallback would swallow it
  # (false || nil → nil), reading every unblocked pair as blocked.
  defp conversation_secret_flag(conversation) do
    case {Map.get(conversation, :secret), Map.get(conversation, "secret")} do
      {value, _} when is_boolean(value) -> value
      {_, value} when is_boolean(value) -> value
      _ -> false
    end
  end

  defp blocked?(sender_id, recipient_id) do
    case SharedInfra.ConversationClient.either_blocked?(%{
           "user_a" => sender_id,
           "user_b" => recipient_id
         }) do
      {:ok, %{blocked: false}} -> false
      {:ok, %{"blocked" => false}} -> false
      _ -> true
    end
  rescue
    _ -> true
  end

  # "contacts" = the recipient's FAVOURITES (the one persisted contact relation; see AutoReply).
  # Fail OPEN to non-contact (false): audience narrows, never widens, on a check failure.
  defp contact?(recipient_id, sender_id) do
    case SharedInfra.UserClient.list_favourites(%{"owner_user_id" => recipient_id}) do
      {:ok, result} ->
        (mget(result, :favourites) || [])
        |> Enum.any?(&(mget(&1, :user_id) == sender_id))

      _ ->
        false
    end
  rescue
    _ -> false
  end

  # Last activity BEFORE the triggering message: the conversation's updated_at when it meaningfully
  # predates the message (>5 s); otherwise nil = "first message" (the row was created/bumped by this
  # very message). An approximation, recorded in the moduledoc of the decision core.
  defp last_activity_before(conversation, message) do
    with updated when is_binary(updated) <- mget(conversation, :updated_at),
         created when is_binary(created) <- mget(message, :created_at),
         {:ok, updated_at, _} <- DateTime.from_iso8601(updated),
         {:ok, created_at, _} <- DateTime.from_iso8601(created),
         true <- DateTime.diff(created_at, updated_at, :second) > 5 do
      updated_at
    else
      _ -> nil
    end
  end

  # The claim's tenant = the conversation's app (both parties live there by construction).
  defp conversation_app(conversation_id) do
    case SharedInfra.ConversationClient.get_conversation_app(%{
           "conversation_id" => conversation_id
         }) do
      {:ok, result} -> mget(result, :app_id) || SharedInfra.Tenancy.default_app_id()
      _ -> SharedInfra.Tenancy.default_app_id()
    end
  rescue
    _ -> SharedInfra.Tenancy.default_app_id()
  end

  @doc false
  def enabled? do
    Application.get_env(:realtime_gateway, :auto_reply_consumer_enabled, false) ||
      System.get_env("AUTO_REPLY_CONSUMER_ENABLED") in ["true", "1", "yes"]
  end

  defp mget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp mget(_, _), do: nil

  defp mget_atomish(value) when is_atom(value), do: to_string(value)
  defp mget_atomish(value), do: to_string(value)
end
