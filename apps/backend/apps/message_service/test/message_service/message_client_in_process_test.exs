defmodule MessageService.MessageClientInProcessTest do
  @moduledoc """
  Sanity that the default `SharedInfra.MessageClient` adapter delegates FAITHFULLY to
  `MessageService.{Messages,Timeline,Receipts}` — same input, same result (the zero-behavior-change
  guarantee). Plain, Docker-free (message persistence is off by default → the deterministic
  placeholder path, no Repo).
  """
  use ExUnit.Case, async: true

  test "default adapter is the in-process adapter" do
    assert SharedInfra.MessageClient.adapter() == MessageService.MessageClientInProcess
  end

  test "create_message through the client == calling MessageService.Messages directly" do
    attrs = %{
      "conversation_id" => "conv_1",
      "sender_user_id" => "user_1",
      "message_type" => "text",
      "body" => "hi"
    }

    assert SharedInfra.MessageClient.create_message(attrs) ==
             MessageService.Messages.create_message(attrs)
  end

  test "list_messages through the client == MessageService.Messages directly" do
    attrs = %{"conversation_id" => "conv_1"}

    assert SharedInfra.MessageClient.list_messages(attrs) ==
             MessageService.Messages.list_messages(attrs)
  end

  test "list_timeline through the client == MessageService.Timeline.list_messages directly" do
    attrs = %{"conversation_id" => "conv_1"}

    assert SharedInfra.MessageClient.list_timeline(attrs) ==
             MessageService.Timeline.list_messages(attrs)
  end
end
