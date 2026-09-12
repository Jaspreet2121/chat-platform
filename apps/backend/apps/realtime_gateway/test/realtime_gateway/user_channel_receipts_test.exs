defmodule RealtimeGateway.UserChannelReceiptsTest do
  @moduledoc """
  `messages_delivered` on the USER topic — delivered for a thread the user does NOT have open.

  The conversation channel gets membership for free at join. This surface names the conversation in
  the payload, so it MUST run the same gate per push (tenant + participant via
  `TopicAuthorization.authorize_join`), take identity from the socket, respect the same batch cap,
  and land the frame on the CONVERSATION topic so the sender's open thread ticks.

  Docker-free: conversation persistence is switched ON so the join gate actually runs, against a stub
  whose membership answer the test controls.
  """
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  @endpoint RealtimeGateway.TestEndpoint

  @app "44444444-4444-4444-8444-444444444444"

  defmodule ConvStub do
    def start_link, do: Agent.start_link(fn -> %{member: true} end, name: __MODULE__)
    def set_member(v), do: Agent.update(__MODULE__, &Map.put(&1, :member, v))

    # The tenant gate: the conversation exists in this app.
    def get_conversation_app(_attrs), do: {:ok, %{app_id: "44444444-4444-4444-8444-444444444444"}}

    # The membership gate — THE door under test.
    def get_conversation(%{"user_id" => "reader"}) do
      if Agent.get(__MODULE__, & &1.member),
        do: {:ok, %{type: "direct", participants: [%{user_id: "reader"}, %{user_id: "peer"}]}},
        else: {:error, :conversation_forbidden}
    end

    def get_conversation(_attrs), do: {:error, :conversation_forbidden}
  end

  defmodule MsgStub do
    def start_link, do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def persisted, do: Agent.get(__MODULE__, &Enum.reverse/1)

    def mark_delivered(attrs) do
      Agent.update(__MODULE__, &[attrs | &1])
      {:ok, %{status: "delivered"}}
    end

    def mark_read(attrs) do
      Agent.update(__MODULE__, &[Map.put(attrs, "status", "read") | &1])
      {:ok, %{status: "read"}}
    end
  end

  setup do
    start_supervised!(%{id: ConvStub, start: {ConvStub, :start_link, []}})
    start_supervised!(%{id: MsgStub, start: {MsgStub, :start_link, []}})

    prev = %{
      c: Application.get_env(:shared_infra, :conversation_client_adapter),
      m: Application.get_env(:shared_infra, :message_client_adapter),
      persist: Application.get_env(:conversation_service, :conversation_persistence)
    }

    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)

    # ON, so TopicAuthorization actually consults the stub (skeleton mode would wave everyone through).
    Application.put_env(:conversation_service, :conversation_persistence, true)

    on_exit(fn ->
      restore(:shared_infra, :conversation_client_adapter, prev.c)
      restore(:shared_infra, :message_client_adapter, prev.m)
      restore(:conversation_service, :conversation_persistence, prev.persist)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, v), do: Application.put_env(app, key, v)

  defp join_user_topic do
    {:ok, _, socket} =
      RealtimeGateway.UserSocket
      |> socket("user_socket:reader", %{
        current_user_id: "reader",
        user_id: "reader",
        app_id: @app
      })
      |> subscribe_and_join(RealtimeGateway.UserChannel, "user:reader", %{})

    # Listen on the CONVERSATION topic — that is where the sender's open thread is, and where the
    # frame must land.
    @endpoint.subscribe("conversation:dm_1")
    socket
  end

  test "a member's batch persists every id and lands ONE frame on the conversation topic" do
    socket = join_user_topic()
    ids = ["m1", "m2", "m3"]

    ref = push(socket, "messages_delivered", %{"conversation_id" => "dm_1", "message_ids" => ids})
    assert_reply(ref, :ok, %{accepted: 3})

    assert MsgStub.persisted() |> Enum.map(& &1["message_id"]) == ids
    assert Enum.all?(MsgStub.persisted(), &(&1["user_id"] == "reader"))
    assert Enum.all?(MsgStub.persisted(), &(&1["conversation_id"] == "dm_1"))

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "conversation:dm_1",
      event: "receipt_updated",
      payload: frame
    }

    # The SAME contract as the conversation channel's batch frame.
    assert frame |> Map.keys() |> Enum.sort() ==
             [:conversation_id, :event, :payload, :receipt_type, :status, :user_id]

    assert frame.payload |> Map.keys() |> Enum.sort() == ["message_id", "message_ids"]
    assert frame.payload["message_ids"] == ids
    assert frame.payload["message_id"] == "m1"
    assert frame.receipt_type == "delivered"
    assert frame.user_id == "reader"

    refute_receive %Phoenix.Socket.Broadcast{event: "receipt_updated"}
  end

  test "a NON-member is refused — nothing persisted, nothing broadcast (not a weaker door)" do
    ConvStub.set_member(false)
    socket = join_user_topic()

    ref =
      push(socket, "messages_delivered", %{"conversation_id" => "dm_1", "message_ids" => ["m1"]})

    assert_reply(ref, :error, %{code: "realtime.forbidden"})
    assert MsgStub.persisted() == []
    refute_receive %Phoenix.Socket.Broadcast{event: "receipt_updated"}
  end

  test "identity comes from the SOCKET — the payload cannot speak for another user" do
    socket = join_user_topic()

    ref =
      push(socket, "messages_delivered", %{
        "conversation_id" => "dm_1",
        "message_ids" => ["m1"],
        "user_id" => "someone_else"
      })

    assert_reply(ref, :ok)
    assert [%{"user_id" => "reader"}] = MsgStub.persisted()
  end

  test "the SAME batch cap as the conversation channel — 101 refused, 100 accepted" do
    socket = join_user_topic()
    too_many = for i <- 1..101, do: "m#{i}"

    ref =
      push(socket, "messages_delivered", %{"conversation_id" => "dm_1", "message_ids" => too_many})

    assert_reply(ref, :error, %{code: "receipt.batch_too_large"})
    assert MsgStub.persisted() == []

    ref =
      push(socket, "messages_delivered", %{
        "conversation_id" => "dm_1",
        "message_ids" => Enum.take(too_many, 100)
      })

    assert_reply(ref, :ok, %{accepted: 100})
  end

  test "a missing conversation_id or an empty batch is refused before any lookup" do
    socket = join_user_topic()

    ref = push(socket, "messages_delivered", %{"message_ids" => ["m1"]})
    assert_reply(ref, :error, %{code: "receipt.invalid_request"})

    ref = push(socket, "messages_delivered", %{"conversation_id" => "dm_1", "message_ids" => []})
    assert_reply(ref, :error, %{code: "receipt.invalid_request"})

    assert MsgStub.persisted() == []
  end
end
