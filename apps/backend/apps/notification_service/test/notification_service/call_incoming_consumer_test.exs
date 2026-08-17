defmodule NotificationService.CallIncomingConsumerTest do
  @moduledoc """
  The call.events.v1 consumer's decode paths — including the double-encode black hole this fixes: a
  double-encoded event decodes to a BINARY, which used to match a silent ignore clause. Now: a correctly
  single-encoded event dispatches; a double-encoded one is re-decoded ONCE (loudly) and still dispatches;
  anything unrecognised logs instead of vanishing; every message still commits.

  Dispatch is observed via its correlation side-effect: `dispatch/1` runs synchronously in this process and
  puts the event's correlation_id into Logger metadata (`SharedInfra.Correlation`). The push legs themselves
  are config-gated no-ops here (no VAPID/FCM config in test) — sender behaviour has its own suites.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Record

  alias NotificationService.Events.CallIncomingConsumer

  Record.defrecordp(
    :kafka_message,
    Record.extract(:kafka_message, from_lib: "kafka_protocol/include/kpro_public.hrl")
  )

  setup do
    # Fresh correlation per test (Logger metadata is process-local; tests run in their own process, but be
    # explicit so a dispatch assertion can never bleed).
    Logger.metadata(correlation_id: nil)
    :ok
  end

  defp handle!(raw_value) do
    message = kafka_message(value: raw_value, key: "k", offset: 0)
    CallIncomingConsumer.handle_message(message, :state)
  end

  defp event(correlation) do
    %{
      "type" => "call.incoming",
      "call_id" => "call-1",
      "callee_id" => "callee-1",
      "caller_name" => "Alice",
      "call_type" => "voice",
      "correlation_id" => correlation
    }
  end

  test "a correctly SINGLE-encoded call.incoming dispatches (and commits)" do
    corr = "corr-#{System.unique_integer([:positive])}"

    assert {:ok, :commit, :state} = handle!(Jason.encode!(event(corr)))

    # dispatch/1 ran — it put the event's correlation into this process's metadata.
    assert SharedInfra.Correlation.get() == corr
  end

  test "a DOUBLE-encoded event (the shipped bug's exact wire shape) logs AND still dispatches" do
    corr = "corr-#{System.unique_integer([:positive])}"
    double = Jason.encode!(Jason.encode!(event(corr)))

    log =
      capture_log(fn ->
        assert {:ok, :commit, :state} = handle!(double)
      end)

    assert log =~ "DOUBLE-ENCODED call event"
    # The defensive re-decode dispatched it anyway — in-flight legacy events still push.
    assert SharedInfra.Correlation.get() == corr
  end

  test "an unknown MAP type on the topic logs (never silently ignored again) and does NOT dispatch" do
    log =
      capture_log(fn ->
        assert {:ok, :commit, :state} =
                 handle!(Jason.encode!(%{"type" => "call.weird", "x" => 1}))
      end)

    assert log =~ "unrecognised event on call.events.v1"
    assert SharedInfra.Correlation.get() == nil
  end

  test "a double-encoded NON-call payload logs as unrecognised (one re-decode attempt only)" do
    log =
      capture_log(fn ->
        assert {:ok, :commit, :state} =
                 handle!(Jason.encode!(Jason.encode!(%{"type" => "other"})))
      end)

    assert log =~ "unrecognised event on call.events.v1"
    assert SharedInfra.Correlation.get() == nil
  end

  test "undecodable bytes log the decode failure and still commit (poison can't wedge the partition)" do
    log =
      capture_log(fn ->
        assert {:ok, :commit, :state} = handle!("{not json")
      end)

    assert log =~ "JSON decode failed"
  end

  test "a call.cancelled event dispatches (the stop-ringing branch) and commits" do
    corr = "corr-#{System.unique_integer([:positive])}"

    cancelled = %{
      "type" => "call.cancelled",
      "call_id" => "call-1",
      "callee_id" => "callee-1",
      "caller_id" => "caller-1",
      "reason" => "cancelled",
      "correlation_id" => corr
    }

    assert {:ok, :commit, :state} = handle!(Jason.encode!(cancelled))

    # dispatch_cancel/1 ran — same correlation side-effect as the incoming branch (the FCM leg itself
    # is config-gated off here; its behaviour has its own suite).
    assert SharedInfra.Correlation.get() == corr
  end
end
