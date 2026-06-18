defmodule ConversationService.ConversationClientInProcessTest do
  @moduledoc """
  Sanity that the default `SharedInfra.ConversationClient` adapter delegates FAITHFULLY to
  `ConversationService.*` — same input, same result (the zero-behavior-change guarantee for
  routing edge apps through the client boundary). Plain, Docker-free (conversation persistence
  is off by default → the placeholder path, no Repo).
  """
  use ExUnit.Case, async: true

  test "default adapter is the in-process adapter" do
    assert SharedInfra.ConversationClient.adapter() ==
             ConversationService.ConversationClientInProcess
  end

  test "get_conversation through the client == calling ConversationService.Conversations directly" do
    attrs = %{"conversation_id" => "conv_123", "user_id" => "user_123"}

    assert SharedInfra.ConversationClient.get_conversation(attrs) ==
             ConversationService.Conversations.get_conversation(attrs)
  end
end
