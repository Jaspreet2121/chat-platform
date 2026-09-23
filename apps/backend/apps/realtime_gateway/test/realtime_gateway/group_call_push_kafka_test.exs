defmodule RealtimeGateway.GroupCallPushKafkaTest do
  @moduledoc """
  The GROUP/ADHOC push producer (130-group): `call.group_incoming`, one event per member, keyed by
  that member, behind CALL_GROUP_PUSH_ENABLED (default OFF); and the cancel legs that chase it.

  Driven through the REAL adhoc ring site (`call:adhoc_invite`) with a capturing producer and a
  capturing endpoint, so the test proves the production code path — not a helper called in
  isolation. No broker anywhere.

  Mutations this is RED for:
    * keying the produce by the CALLER instead of the member (the partition-key rule)
    * producing when the group flag is off
    * dropping the decline cancel leg
  """
  use ExUnit.Case, async: false

  alias RealtimeGateway.Application, as: App
  alias RealtimeGateway.CallSignaling

  @app "00000000-0000-0000-0000-000000000001"
  @caller "11111111-1111-4111-8111-111111111111"
  @t1 "22222222-2222-4222-8222-222222222222"
  @t2 "33333333-3333-4333-8333-333333333333"

  defmodule CaptureProducer do
    @behaviour SharedInfra.Kafka.Producer

    @impl true
    def produce(topic, key, value, opts \\ []) do
      case Application.get_env(:realtime_gateway, :group_push_test_pid) do
        pid when is_pid(pid) -> send(pid, {:produced, topic, key, value, opts})
        _ -> :ok
      end

      {:ok, :captured}
    end
  end

  # The store, as the ring site sees it: create seats the initiator joined and the targets invited;
  # decline flips one row; get_call_with_participants feeds broadcast_group.
  defmodule StoreStub do
    @moduledoc false
    @call %{
      id: "acall_1",
      room_name: "aroom_1",
      kind: "adhoc",
      status: "ringing",
      caller_id: "11111111-1111-4111-8111-111111111111",
      callee_id: nil,
      conversation_id: nil,
      type: "voice"
    }

    def create_adhoc_group_call(attrs) do
      targets = attrs["user_ids"]

      parts =
        [%{call_id: "acall_1", user_id: attrs["initiator_id"], status: "joined"}] ++
          Enum.map(targets, &%{call_id: "acall_1", user_id: &1, status: "invited"})

      {:ok,
       %{
         call: %{@call | caller_id: attrs["initiator_id"]},
         participants: parts,
         member_ids: targets
       }}
    end

    def decline_group_call(%{"call_id" => id, "user_id" => user}),
      do: {:ok, %{call: %{@call | id: id}, participant: %{user_id: user, status: "declined"}}}

    def get_call_with_participants(%{"call_id" => id}),
      do: {:ok, %{call: %{@call | id: id}, participants: []}}
  end

  defmodule CaptureEndpoint do
    @moduledoc false
    def broadcast(topic, event, payload) do
      case Application.get_env(:realtime_gateway, :group_push_test_pid) do
        pid when is_pid(pid) -> send(pid, {:broadcast, topic, event, payload})
        _ -> :ok
      end

      :ok
    end
  end

  defmodule UserStub do
    @moduledoc false
    def get_public_profile(_attrs),
      do: {:ok, %{display_name: "Caller Name", avatar_media_id: nil}}
  end

  defmodule MediaStub do
    @moduledoc false
    def get_download_url(_attrs), do: {:error, :not_found}
  end

  defmodule OkLimiter do
    @moduledoc false
    def check_rate(_attrs), do: :ok
  end

  setup do
    keys = [
      {:shared_infra, :conversation_client_adapter},
      {:shared_infra, :user_client_adapter},
      {:shared_infra, :media_client_adapter},
      {:shared_infra, :rate_limiter_adapter},
      {:shared_infra, :kafka_producer_adapter},
      {:realtime_gateway, :call_push_enabled},
      {:realtime_gateway, :group_call_push_enabled},
      {:realtime_gateway, :group_push_test_pid}
    ]

    prev = for {app, key} <- keys, into: %{}, do: {{app, key}, Application.get_env(app, key)}

    Application.put_env(:shared_infra, :conversation_client_adapter, StoreStub)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)
    Application.put_env(:shared_infra, :rate_limiter_adapter, OkLimiter)
    Application.put_env(:shared_infra, :kafka_producer_adapter, CaptureProducer)
    Application.put_env(:realtime_gateway, :group_push_test_pid, self())
    Application.delete_env(:realtime_gateway, :call_push_enabled)
    Application.delete_env(:realtime_gateway, :group_call_push_enabled)

    on_exit(fn ->
      for {{app, key}, value} <- prev do
        if value == nil,
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end
    end)

    :ok
  end

  defp socket(user_id),
    do: %{assigns: %{current_user_id: user_id, app_id: @app}, endpoint: CaptureEndpoint}

  defp invite!,
    do:
      CallSignaling.handle_event(
        "call:adhoc_invite",
        %{"user_ids" => [@t1, @t2], "type" => "voice"},
        socket(@caller)
      )

  test "flag ON: the adhoc ring produces ONE call.group_incoming PER member, keyed by THAT member" do
    Application.put_env(:realtime_gateway, :group_call_push_enabled, true)

    assert {:reply, {:ok, _}, _} = invite!()

    for member <- [@t1, @t2] do
      assert_receive {:produced, "call.events.v1", ^member, value, opts}, 1000
      assert value["type"] == "call.group_incoming"
      assert value["callee_id"] == member
      assert value["caller_id"] == @caller
      assert value["kind"] == "adhoc"
      assert value["call_id"] == "acall_1"
      assert is_binary(value["sent_at"])
      assert is_binary(value["ring_deadline_at"])
      assert opts[:client] == App.kafka_client_name()
    end

    # Never the caller — they are not rung, so they are never keyed.
    refute_receive {:produced, _, @caller, _, _}, 100
  end

  test "flag OFF (even with the direct-call push ON): every member still rings over the socket, NOTHING is produced" do
    Application.put_env(:realtime_gateway, :call_push_enabled, true)
    Application.put_env(:realtime_gateway, :group_call_push_enabled, false)

    assert {:reply, {:ok, _}, _} = invite!()

    assert_receive {:broadcast, "user:" <> @t1, "call:group_incoming", _}, 500
    assert_receive {:broadcast, "user:" <> @t2, "call:group_incoming", _}, 500
    refute_receive {:produced, _, _, _, _}, 300
  end

  test "a group DECLINE produces call.cancelled keyed to the decliner, reason declined" do
    Application.put_env(:realtime_gateway, :group_call_push_enabled, true)

    assert {:reply, {:ok, _}, _} =
             CallSignaling.handle_event(
               "call:group_decline",
               %{"call_id" => "acall_1"},
               socket(@t1)
             )

    assert_receive {:produced, "call.events.v1", @t1, value, _}, 1000
    assert value["type"] == "call.cancelled"
    assert value["callee_id"] == @t1
    assert value["reason"] == "declined"
    assert value["call_id"] == "acall_1"
  end

  test "the brod client comes up for the GROUP flag alone (the gate knows both producers)" do
    Application.put_env(:shared_infra, :kafka_producer_adapter, SharedInfra.Kafka.BrodProducer)
    Application.put_env(:realtime_gateway, :group_call_push_enabled, true)
    assert App.kafka_client_needed?()
  end
end
