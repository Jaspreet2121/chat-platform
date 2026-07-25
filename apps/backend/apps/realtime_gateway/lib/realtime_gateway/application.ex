defmodule RealtimeGateway.Application do
  @moduledoc false

  use Application

  require Logger

  # The gateway's OWN brod client. NEVER :message_service_kafka_client — that client is started by
  # MessageService.Application in the message-service release; in the GATEWAY release it does not exist,
  # which is exactly the bug this fixes (see kafka_children/0).
  @kafka_client :realtime_gateway_kafka_client

  @doc "The gateway's brod client name — passed per-call to the producer (BrodProducer opts[:client])."
  def kafka_client_name, do: @kafka_client

  @impl true
  def start(_type, _args) do
    children =
      [
        {Phoenix.PubSub, name: RealtimeGateway.PubSub},
        RealtimeGateway.Presence,
        # Owns the ETS table backing the connection counter's :ets backend (single-node / dev / tests).
        RealtimeGateway.ConnectionCounter.Table
      ] ++ kafka_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: RealtimeGateway.Supervisor)
  end

  @doc """
  Flag-gated brod client for the gateway's ONE producer: `CallSignaling.emit_incoming_push` (call.incoming →
  call.events.v1 → the notification service's push consumer).

  THE BUG THIS FIXES: with `KAFKA_PRODUCER_ADAPTER=brod` the produce dispatched to BrodProducer, whose
  client defaulted to `:message_service_kafka_client` — a process started only by MessageService.Application
  (its own release). In the gateway release NO brod client existed, so `:brod.produce` errored and the emit's
  fire-and-forget rescue swallowed it: message pushes worked (message-service produces those itself), but
  incoming-CALL pushes for a closed app silently never fired.

  Starts ONLY when the brod adapter is selected AND call push is enabled — with either off this returns []
  and nothing connects at boot (plain `mix test` stays Docker-free). Mirrors
  MessageService.Application / ConversationService.Application (no shared helper exists in shared_infra yet;
  the broker parsing is copied from ConversationService.Application.parse_endpoints/1). Brokers come from
  `:realtime_gateway, :kafka` — already populated from KAFKA_BROKERS by runtime.exs.

  Public (and broker-free until a child actually STARTS) so the decision is unit-testable.
  """
  def kafka_children do
    client = if kafka_client_needed?(), do: [brod_client_child_spec()], else: []

    # The boot-time audit the other producing services already have — a silent supervision tree is
    # precisely how this misconfiguration class stays invisible.
    Logger.info(
      "kafka producer: #{inspect(Application.get_env(:shared_infra, :kafka_producer_adapter))}, " <>
        "brod client #{if client == [], do: "OFF", else: "ON"} (realtime_gateway)"
    )

    client
  end

  @doc "True iff the gateway needs a brod client: brod adapter selected AND call push enabled."
  def kafka_client_needed? do
    brod_producer_selected?() and RealtimeGateway.CallSignaling.call_push_enabled?()
  end

  defp brod_producer_selected? do
    Application.get_env(:shared_infra, :kafka_producer_adapter) == SharedInfra.Kafka.BrodProducer
  end

  defp brod_client_child_spec do
    endpoints =
      :realtime_gateway
      |> Application.get_env(:kafka, [])
      |> Keyword.get(:brokers, "localhost:9094")
      |> parse_endpoints()

    %{
      id: @kafka_client,
      start: {:brod, :start_link_client, [endpoints, @kafka_client, [auto_start_producers: true]]}
    }
  end

  # Mirrored from ConversationService.Application.parse_endpoints/1 (the established shape; extract a shared
  # helper only when a third copy appears).
  defp parse_endpoints(brokers) do
    brokers
    |> String.split(",", trim: true)
    |> Enum.map(fn endpoint ->
      case String.split(endpoint, ":", parts: 2) do
        [host, port] -> {String.to_charlist(host), String.to_integer(port)}
        [host] -> {String.to_charlist(host), 9094}
      end
    end)
  end
end
