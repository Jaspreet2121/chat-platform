defmodule ApiGatewayWeb.RealtimeFanOutReplayTest do
  @moduledoc """
  A REPLAYED message_created fans out to nobody. The idempotency ledger returns the first write's
  message for a resent client_msg_id, flagged `replayed: true`; every transport used to fan that out
  again, so a client's retry of a lost ack put the message on everyone else's screen twice. The
  gate lives in the one helper both REST paths use, and this pins it without a socket or a store.
  """
  use ExUnit.Case, async: false

  alias ApiGatewayWeb.RealtimeFanOut

  @conversation "11111111-1111-1111-1111-111111111111"

  setup do
    :ok = Phoenix.PubSub.subscribe(ApiGateway.PubSub, "conversation:" <> @conversation)
    :ok
  end

  test "a first write is broadcast; its replay is not" do
    RealtimeFanOut.to_conversation(@conversation, "message_created", %{message_id: "m1"})

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "message_created",
                     payload: %{message_id: "m1"}
                   },
                   500

    RealtimeFanOut.to_conversation(@conversation, "message_created", %{
      message_id: "m1",
      replayed: true
    })

    refute_receive %Phoenix.Socket.Broadcast{event: "message_created"}, 200

    # String keys, as an HTTP-adapter response arrives, are the same replay.
    RealtimeFanOut.to_conversation(@conversation, "message_created", %{
      "message_id" => "m1",
      "replayed" => true
    })

    refute_receive %Phoenix.Socket.Broadcast{event: "message_created"}, 200
  end

  test "only message_created is gated — a replayed flag on any other event is ignored" do
    RealtimeFanOut.to_conversation(@conversation, "message_updated", %{
      message_id: "m1",
      replayed: true
    })

    assert_receive %Phoenix.Socket.Broadcast{event: "message_updated"}, 500
  end
end
