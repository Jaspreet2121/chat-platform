defmodule RealtimeGateway.AdhocInviteSignalingTest do
  @moduledoc """
  `call:adhoc_invite` — the signaling half of ad-hoc conversationless group calls (116).

  ORDER IS THE SECURITY PROPERTY UNDER TEST: validate → rate limit → store gate → ring. The fan-out
  is LAST, so the central assertion style here is "a refused invite broadcasts ZERO frames" —
  subscribed to the would-be targets' user topics via the capture endpoint, then refuted.

  The limiter is FAIL-CLOSED and deliberately not RealtimeGateway.Limits (fail-open): an N-target
  ring with no shared context is a spam amplifier, and the degraded-limiter case refuses exactly like
  the over-limit case (the media-limiter precedent).
  """
  use ExUnit.Case, async: false

  alias RealtimeGateway.CallSignaling

  @app "00000000-0000-0000-0000-000000000001"
  @caller "11111111-1111-4111-8111-111111111111"
  @t1 "22222222-2222-4222-8222-222222222222"
  @t2 "33333333-3333-4333-8333-333333333333"

  defmodule AdhocMockClient do
    @moduledoc false
    # The store seam: succeeds (recording the attrs) unless :adhoc_store_result overrides — the
    # refusal tests make the STORE refuse, then assert the wire behaviour (code + zero rings).
    def create_adhoc_group_call(attrs) do
      case Application.get_env(:realtime_gateway, :adhoc_store_result) do
        nil ->
          targets = attrs["user_ids"]

          call = %{
            id: "acall_1",
            room_name: "aroom_1",
            kind: "adhoc",
            status: "ringing",
            caller_id: attrs["initiator_id"],
            callee_id: nil,
            conversation_id: nil,
            type: attrs["type"]
          }

          parts =
            [%{call_id: "acall_1", user_id: attrs["initiator_id"], status: "joined"}] ++
              Enum.map(targets, &%{call_id: "acall_1", user_id: &1, status: "invited"})

          send(Application.get_env(:realtime_gateway, :call_test_pid), {:store_create, attrs})
          {:ok, %{call: call, participants: parts, member_ids: targets}}

        result ->
          send(Application.get_env(:realtime_gateway, :call_test_pid), {:store_create, attrs})
          result
      end
    end
  end

  defmodule CaptureEndpoint do
    @moduledoc false
    def broadcast(topic, event, payload) do
      case Application.get_env(:realtime_gateway, :call_test_pid) do
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

  defmodule OverLimiter do
    @moduledoc false
    def check_rate(_attrs), do: {:error, :rate_limited, 42}
  end

  defmodule BrokenLimiter do
    @moduledoc false
    # A limiter outage: not :ok, not the rate-limited tuple — the degraded branch.
    def check_rate(_attrs), do: {:error, :redis_down}
  end

  setup do
    keys = [
      {:shared_infra, :conversation_client_adapter},
      {:shared_infra, :user_client_adapter},
      {:shared_infra, :media_client_adapter},
      {:shared_infra, :rate_limiter_adapter},
      {:realtime_gateway, :call_test_pid},
      {:realtime_gateway, :adhoc_store_result}
    ]

    prev = for {app, key} <- keys, into: %{}, do: {{app, key}, Application.get_env(app, key)}

    Application.put_env(:shared_infra, :conversation_client_adapter, AdhocMockClient)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)
    Application.put_env(:shared_infra, :rate_limiter_adapter, OkLimiter)
    Application.put_env(:realtime_gateway, :call_test_pid, self())
    Application.delete_env(:realtime_gateway, :adhoc_store_result)

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
    do: %{
      assigns: %{current_user_id: user_id, app_id: @app},
      endpoint: CaptureEndpoint
    }

  defp invite(payload, user \\ @caller),
    do: CallSignaling.handle_event("call:adhoc_invite", payload, socket(user))

  defp assert_error(result, code) do
    assert {:reply, {:error, %{code: ^code}}, _socket} = result
  end

  defp refute_any_ring do
    refute_receive {:broadcast, _topic, "call:group_incoming", _payload}, 150
  end

  # --- the happy path ------------------------------------------------------------------------------

  test "rings every target on their user topic with the group_incoming frame, nil conversation" do
    assert {:reply, {:ok, %{call_id: "acall_1", room: "aroom_1", participants: parts}}, _} =
             invite(%{"user_ids" => [@t1, @t2], "type" => "voice"})

    assert length(parts) == 3
    assert_receive {:broadcast, "user:" <> u1, "call:group_incoming", p1}
    assert_receive {:broadcast, "user:" <> u2, "call:group_incoming", p2}
    assert Enum.sort([u1, u2]) == Enum.sort([@t1, @t2])

    # KEY-SET assertion on the ring frame — the client contract for a call with no conversation.
    assert p1 |> Map.keys() |> Enum.sort() ==
             [:call_id, :caller_id, :caller_name, :conversation_id, :participants, :room, :type]

    assert p1.conversation_id == nil
    assert p1.caller_id == @caller
    assert p2.call_id == "acall_1"

    # The store received the caller's SOCKET identity + tenant, never payload identity.
    assert_receive {:store_create, attrs}
    assert attrs["initiator_id"] == @caller
    assert attrs["app_id"] == @app
  end

  # --- 9. normalisation at the wire ----------------------------------------------------------------

  test "dupes and self are dropped before the store sees the list" do
    assert {:reply, {:ok, _}, _} =
             invite(%{"user_ids" => [@t1, @t1, @caller, @t2], "type" => "voice"})

    assert_receive {:store_create, attrs}
    assert attrs["user_ids"] == [@t1, @t2]
  end

  test "malformed lists refuse with call.invalid_request and ring NOBODY" do
    for bad <- [
          %{"user_ids" => [], "type" => "voice"},
          %{"user_ids" => [@caller], "type" => "voice"},
          %{"user_ids" => ["not-a-uuid"], "type" => "voice"},
          %{"user_ids" => [@t1, 42], "type" => "voice"},
          %{"user_ids" => "not-a-list", "type" => "voice"},
          %{"user_ids" => [@t1], "type" => "screaming"},
          %{"type" => "voice"}
        ] do
      bad |> invite() |> assert_error("call.invalid_request")
    end

    refute_any_ring()
    refute_received {:store_create, _}
  end

  test "9 targets refuse at the wire; 8 pass" do
    nine = for i <- 1..9, do: "aaaaaaa#{i}-0000-4000-8000-00000000000#{i}"

    nine
    |> then(&invite(%{"user_ids" => &1, "type" => "voice"}))
    |> assert_error("call.invalid_request")

    refute_any_ring()

    assert {:reply, {:ok, _}, _} = invite(%{"user_ids" => Enum.take(nine, 8), "type" => "voice"})
  end

  # --- 5. the limiter: fail-closed, before the store -----------------------------------------------

  test "over the limit → call.rate_limited, the STORE is never called, NOBODY rings" do
    Application.put_env(:shared_infra, :rate_limiter_adapter, OverLimiter)

    invite(%{"user_ids" => [@t1], "type" => "voice"}) |> assert_error("call.rate_limited")

    refute_any_ring()
    refute_received {:store_create, _}
  end

  test "a DEGRADED limiter refuses exactly like an over-limit one (fail closed)" do
    Application.put_env(:shared_infra, :rate_limiter_adapter, BrokenLimiter)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        invite(%{"user_ids" => [@t1], "type" => "voice"}) |> assert_error("call.rate_limited")
      end)

    assert log =~ "DEGRADED (failing closed)"
    refute_any_ring()
    refute_received {:store_create, _}
  end

  # --- 6. NO RING BEFORE CHECKS — the refused-store case -------------------------------------------

  test "a store refusal (invalid_targets) reaches the caller as ONE uniform code and rings NOBODY" do
    Application.put_env(:realtime_gateway, :adhoc_store_result, {:error, :invalid_targets})

    invite(%{"user_ids" => [@t1, @t2], "type" => "voice"}) |> assert_error("call.invalid_targets")

    refute_any_ring()
  end

  test "a store outage refuses as call.unavailable and rings NOBODY" do
    Application.put_env(
      :realtime_gateway,
      :adhoc_store_result,
      {:error, :conversation_unavailable}
    )

    invite(%{"user_ids" => [@t1], "type" => "voice"}) |> assert_error("call.unavailable")
    refute_any_ring()
  end
end
