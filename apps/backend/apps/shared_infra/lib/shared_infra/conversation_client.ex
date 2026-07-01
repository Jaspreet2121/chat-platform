defmodule SharedInfra.ConversationClient do
  @moduledoc """
  Client boundary for the Conversation service — lets edge apps (api_gateway,
  realtime_gateway) stop calling `ConversationService.*` in-process directly.

  Same pattern as `SharedInfra.AuthClient` / `SharedInfra.Kafka.Producer`: behaviour AND
  configured dispatcher. The adapter is selected from `:shared_infra, :conversation_client_adapter`
  (config default `ConversationService.ConversationClientInProcess`, which delegates in-process
  → zero behavior change). A future `CONVERSATION_CLIENT_ADAPTER=http` selects an HTTP adapter
  (separate conversation-service container) WITHOUT touching call sites.

  shared_infra does NOT compile-depend on conversation_service: the adapter module is resolved
  from config at runtime, so the base lib stays free of a service dependency.
  """

  @type attrs :: map()
  @type result :: {:ok, map()} | {:error, term()}

  @callback create_conversation(attrs()) :: result()
  @callback list_conversations(attrs()) :: result()
  @callback get_conversation(attrs()) :: result()
  @callback add_participant(attrs()) :: result()
  @callback remove_participant(attrs()) :: result()
  @callback get_conversation_app(attrs()) :: result()
  @callback get_call_conversation(attrs()) :: result()

  # Optional so existing test stubs of this behaviour don't all need it; the real adapters implement it.
  @optional_callbacks get_conversation_app: 1, get_call_conversation: 1

  def create_conversation(attrs), do: adapter().create_conversation(attrs)
  def list_conversations(attrs), do: adapter().list_conversations(attrs)
  def get_conversation(attrs), do: adapter().get_conversation(attrs)
  def add_participant(attrs), do: adapter().add_participant(attrs)
  def remove_participant(attrs), do: adapter().remove_participant(attrs)
  def get_conversation_app(attrs), do: adapter().get_conversation_app(attrs)
  def get_call_conversation(attrs), do: adapter().get_call_conversation(attrs)

  @doc "The configured Conversation client adapter (default `ConversationService.ConversationClientInProcess`)."
  def adapter do
    Application.get_env(
      :shared_infra,
      :conversation_client_adapter,
      ConversationService.ConversationClientInProcess
    )
  end
end
