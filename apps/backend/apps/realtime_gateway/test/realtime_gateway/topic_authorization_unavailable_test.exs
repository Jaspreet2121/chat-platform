defmodule RealtimeGateway.TopicAuthorizationUnavailableStub do
  @moduledoc false
  @behaviour SharedInfra.ConversationClient
  @impl true
  def get_conversation(_attrs), do: {:error, :conversation_unavailable}
  @impl true
  def get_conversation_app(_attrs), do: {:error, :conversation_unavailable}
  @impl true
  def create_conversation(_attrs), do: {:error, :conversation_unavailable}
  @impl true
  def list_conversations(_attrs), do: {:error, :conversation_unavailable}
  @impl true
  def add_participant(_attrs), do: {:error, :conversation_unavailable}
  @impl true
  def remove_participant(_attrs), do: {:error, :conversation_unavailable}
end

defmodule RealtimeGateway.TopicAuthorizationUnavailableTest do
  @moduledoc """
  Plain (Docker-free, no network): when the Conversation client is unreachable, a conversation
  join is rejected with a distinct `realtime.unavailable` signal (not forbidden/internal_error).
  conversation_persistence is enabled so membership is actually checked.
  """
  use ExUnit.Case, async: false

  alias RealtimeGateway.TopicAuthorization
  alias RealtimeGateway.TopicAuthorizationUnavailableStub

  setup do
    prev_conv = Application.get_env(:shared_infra, :conversation_client_adapter)
    prev_persist = Application.get_env(:conversation_service, :conversation_persistence, false)

    Application.put_env(
      :shared_infra,
      :conversation_client_adapter,
      TopicAuthorizationUnavailableStub
    )

    Application.put_env(:conversation_service, :conversation_persistence, true)

    on_exit(fn ->
      if prev_conv,
        do: Application.put_env(:shared_infra, :conversation_client_adapter, prev_conv),
        else: Application.delete_env(:shared_infra, :conversation_client_adapter)

      Application.put_env(:conversation_service, :conversation_persistence, prev_persist)
    end)

    :ok
  end

  test "conversation join → realtime.unavailable when conversation service is unreachable" do
    socket = %{assigns: %{current_user_id: "user_1"}}

    assert {:error, %{code: "realtime.unavailable"}} =
             TopicAuthorization.authorize_join("conversation:conv_1", socket)
  end
end
