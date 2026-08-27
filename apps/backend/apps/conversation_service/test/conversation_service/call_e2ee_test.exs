defmodule ConversationService.CallE2eeTest do
  @moduledoc """
  E2EE calls (111 / E2EE_FRAME.md §calls) at the store boundary.

  The server's whole job here is to relay ONE OPAQUE BLOB and carry two booleans. So what these tests
  pin is exactly that boundary: the shape it refuses, the fact that it never rewrites what it accepts,
  that a callee can still fetch its envelope while the call rings, and that the envelopes are GONE the
  moment the call is over while the durable booleans survive for history.

  What is deliberately NOT tested here (because the server must not do it): opening an envelope,
  deciding the mode, or downgrading a call. Mode is a client agreement.
  """
  use ConversationService.DataCase, async: false

  alias ConversationService.CallStore

  @tenant_zero "00000000-0000-0000-0000-000000000001"

  setup do
    previous = Application.get_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:conversation_service, :conversation_persistence, true)

    on_exit(fn ->
      Application.put_env(:conversation_service, :conversation_persistence, previous)
    end)

    :ok
  end

  # A user with `count` live devices. Returns {user_id, [device_id]}.
  defp user_with_devices!(count) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, password_hash, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', 'active', now(), now())",
      [id, @tenant_zero, "+1#{System.unique_integer([:positive])}"]
    )

    devices =
      for _ <- 1..count do
        device = "dev-#{System.unique_integer([:positive])}"

        Repo.query!(
          "INSERT INTO device_sessions (id, user_id, device_id, platform, refresh_token_hash, created_at) " <>
            "VALUES ($1::text::uuid, $2::text::uuid, $3, 'android', 'h', now())",
          [Ecto.UUID.generate(), id, device]
        )

        device
      end

    {id, devices}
  end

  defp envelope(device_id, blob \\ "sealed-key-bytes"),
    do: %{"device_id" => device_id, "envelope_b64" => Base.encode64(blob)}

  defp offer(sender_device, envelopes),
    do: %{"v" => 1, "sender_device_id" => sender_device, "envelopes" => envelopes}

  defp create!(caller, callee, extra \\ %{}) do
    CallStore.create_call(
      Map.merge(
        %{"caller_id" => caller, "callee_id" => callee, "type" => "voice"},
        extra
      )
    )
  end

  describe "offer shape validation" do
    @tag :postgres_integration
    test "a well-formed offer to both parties' live devices is accepted and stored VERBATIM" do
      {caller, [caller_dev, caller_dev2]} = user_with_devices!(2)
      {callee, [callee_dev]} = user_with_devices!(1)

      sent = offer(caller_dev, [envelope(callee_dev), envelope(caller_dev2)])
      assert {:ok, call} = create!(caller, callee, %{"e2ee_offer" => sent})

      assert call.e2ee == true
      assert is_nil(call.e2ee_accepted)
      # Byte-for-byte: normalising would change bytes a client may hash or compare.
      assert call.e2ee_offer == sent
    end

    @tag :postgres_integration
    test "a FOREIGN device_id is refused — we never relay a key to an outsider" do
      {caller, [caller_dev]} = user_with_devices!(1)
      {callee, [_callee_dev]} = user_with_devices!(1)
      {_stranger, [stranger_dev]} = user_with_devices!(1)

      assert {:error, :call_invalid_e2ee_offer} =
               create!(caller, callee, %{
                 "e2ee_offer" => offer(caller_dev, [envelope(stranger_dev)])
               })
    end

    @tag :postgres_integration
    test "a REVOKED device is not a live device" do
      {caller, [caller_dev]} = user_with_devices!(1)
      {callee, [callee_dev]} = user_with_devices!(1)

      Repo.query!("UPDATE device_sessions SET revoked_at = now() WHERE device_id = $1", [
        callee_dev
      ])

      assert {:error, :call_invalid_e2ee_offer} =
               create!(caller, callee, %{
                 "e2ee_offer" => offer(caller_dev, [envelope(callee_dev)])
               })
    end

    @tag :postgres_integration
    test "the caps hold: at most 20 envelopes, at most 32 KB, v must be 1, b64 must decode" do
      {caller, [caller_dev]} = user_with_devices!(1)
      {callee, [callee_dev]} = user_with_devices!(1)

      bad = fn o -> create!(caller, callee, %{"e2ee_offer" => o}) end

      # 21 envelopes — over the count cap (all addressed to a real device, so ONLY the cap can refuse it).
      too_many = for _ <- 1..21, do: envelope(callee_dev)
      assert {:error, :call_invalid_e2ee_offer} = bad.(offer(caller_dev, too_many))

      # Over the 32 KB total.
      huge = offer(caller_dev, [envelope(callee_dev, :binary.copy(<<7>>, 40_000))])
      assert {:error, :call_invalid_e2ee_offer} = bad.(huge)

      # Wrong version.
      assert {:error, :call_invalid_e2ee_offer} =
               bad.(%{offer(caller_dev, [envelope(callee_dev)]) | "v" => 2})

      # Not base64.
      assert {:error, :call_invalid_e2ee_offer} =
               bad.(
                 offer(caller_dev, [
                   %{"device_id" => callee_dev, "envelope_b64" => "not base64!!"}
                 ])
               )

      # Empty / missing pieces.
      assert {:error, :call_invalid_e2ee_offer} = bad.(offer(caller_dev, []))
      assert {:error, :call_invalid_e2ee_offer} = bad.(%{"v" => 1, "envelopes" => []})
      assert {:error, :call_invalid_e2ee_offer} = bad.("not a map")
    end
  end

  describe "the pre-E2EE path is untouched" do
    @tag :postgres_integration
    test "a call with NO offer is byte-identical to before: e2ee false, offer nil, nothing else moves" do
      {caller, _} = user_with_devices!(1)
      {callee, _} = user_with_devices!(1)

      assert {:ok, call} = create!(caller, callee)

      assert call.e2ee == false
      assert is_nil(call.e2ee_offer)
      assert is_nil(call.e2ee_accepted)
      assert call.status == "ringing"

      # And it answers + ends exactly as it always did.
      assert {:ok, answered} = CallStore.mark_answered(%{"call_id" => call.id})
      assert answered.status == "accepted"
      # No offer was made, so no mode was negotiated — NOT a claim of "false".
      assert is_nil(answered.e2ee_accepted)

      assert {:ok, ended} = CallStore.mark_ended(%{"call_id" => call.id})
      assert ended.status == "ended"
      assert ended.e2ee == false
    end
  end

  describe "relay fidelity" do
    @tag :postgres_integration
    test "a ringing call SERVES the offer back, so a push-woken callee can find its envelope" do
      {caller, [caller_dev]} = user_with_devices!(1)
      {callee, [callee_dev]} = user_with_devices!(1)

      sent = offer(caller_dev, [envelope(callee_dev)])
      {:ok, call} = create!(caller, callee, %{"e2ee_offer" => sent})

      assert {:ok, fetched} = CallStore.get_call(%{"call_id" => call.id})
      assert fetched.e2ee_offer == sent
      assert fetched.e2ee == true

      # The callee's own envelope is findable by its device_id — the §calls receive step.
      mine = Enum.find(fetched.e2ee_offer["envelopes"], &(&1["device_id"] == callee_dev))
      assert {:ok, _bytes} = Base.decode64(mine["envelope_b64"])
    end

    @tag :postgres_integration
    test "the accepted flag is relayed in both directions" do
      {caller, [caller_dev]} = user_with_devices!(1)
      {callee, [callee_dev]} = user_with_devices!(1)
      sent = offer(caller_dev, [envelope(callee_dev)])

      {:ok, yes} = create!(caller, callee, %{"e2ee_offer" => sent})
      assert {:ok, a} = CallStore.mark_answered(%{"call_id" => yes.id, "e2ee_accepted" => true})
      assert a.e2ee_accepted == true

      {:ok, no} = create!(caller, callee, %{"e2ee_offer" => sent})
      assert {:ok, b} = CallStore.mark_answered(%{"call_id" => no.id, "e2ee_accepted" => false})
      assert b.e2ee_accepted == false
    end

    @tag :postgres_integration
    test "KEYLESS/OLD CALLEE: an offer is made, the callee just answers — nothing breaks" do
      {caller, [caller_dev]} = user_with_devices!(1)
      {callee, [callee_dev]} = user_with_devices!(1)

      # The offer went out (the caller was capable), but this callee is an old client: it neither
      # opens an envelope nor sends the flag. The call must simply proceed, unencrypted.
      {:ok, call} =
        create!(caller, callee, %{"e2ee_offer" => offer(caller_dev, [envelope(callee_dev)])})

      assert {:ok, answered} = CallStore.mark_answered(%{"call_id" => call.id})
      assert answered.status == "accepted"
      assert is_nil(answered.e2ee_accepted)

      assert {:ok, ended} = CallStore.mark_ended(%{"call_id" => call.id})
      assert ended.status == "ended"
    end
  end

  describe "scrub on end" do
    @tag :postgres_integration
    test "EVERY terminal status nulls the envelopes and KEEPS the booleans" do
      {caller, [caller_dev]} = user_with_devices!(1)
      {callee, [callee_dev]} = user_with_devices!(1)
      sent = offer(caller_dev, [envelope(callee_dev)])

      terminals = [
        {&CallStore.mark_ended/1, "ended"},
        {&CallStore.mark_declined/1, "declined"},
        {&CallStore.mark_missed/1, "missed"},
        {&CallStore.mark_cancelled/1, "cancelled"}
      ]

      for {terminate, status} <- terminals do
        {:ok, call} = create!(caller, callee, %{"e2ee_offer" => sent})
        assert call.e2ee_offer == sent

        assert {:ok, done} = terminate.(%{"call_id" => call.id})
        assert done.status == status

        # THE POINT: the key died with the call, so a retained envelope is pure liability.
        assert is_nil(done.e2ee_offer), "#{status} left envelopes behind"
        # ...but the lock badge must still render on the history row.
        assert done.e2ee == true

        # And a later fetch cannot recover them either.
        assert {:ok, refetched} = CallStore.get_call(%{"call_id" => call.id})
        assert is_nil(refetched.e2ee_offer)
        assert refetched.e2ee == true
      end
    end

    @tag :postgres_integration
    test "an answered E2EE call keeps its agreed mode through the scrub" do
      {caller, [caller_dev]} = user_with_devices!(1)
      {callee, [callee_dev]} = user_with_devices!(1)

      {:ok, call} =
        create!(caller, callee, %{"e2ee_offer" => offer(caller_dev, [envelope(callee_dev)])})

      {:ok, _} = CallStore.mark_answered(%{"call_id" => call.id, "e2ee_accepted" => true})
      assert {:ok, ended} = CallStore.mark_ended(%{"call_id" => call.id})

      assert is_nil(ended.e2ee_offer)
      assert ended.e2ee == true
      assert ended.e2ee_accepted == true
    end
  end
end
