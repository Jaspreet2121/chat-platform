defmodule NotificationService.MessageCreatedPoisonTest do
  @moduledoc """
  POISON CLASSIFICATION for the notification consumer — the one that is LIVE IN PRODUCTION
  (`NOTIFICATION_CONSUMER_ENABLED: "true"`).

  Its `commit_decision/2` used to retry every error that was not `:invalid_event`, on the stated
  assumption that anything else was "transient DB". A permanent failure — a type mismatch, a
  constraint violation, a shape the code cannot handle — therefore retried forever and WEDGED THE
  PARTITION: nothing behind the stuck offset is ever delivered, and nothing errors loudly enough to
  notice. The same defect was found by running its sibling against a real broker.

  Docker-free by construction: `commit_decision/2` is a pure function of the apply result, so this
  guards the DECISION without needing Kafka or Postgres.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias NotificationService.Events.MessageCreatedConsumer

  test "a PERMANENT error COMMITS (skips) instead of retrying forever" do
    capture_log(fn ->
      # DBConnection.EncodeError cannot succeed on retry — only a code change fixes it. Retrying is
      # what wedges the partition.
      assert :commit =
               MessageCreatedConsumer.commit_decision(
                 {:error, %DBConnection.EncodeError{message: "expected %DateTime{}"}},
                 0
               )
    end)
  end

  test "a TRANSIENT error still RETRIES (does not commit)" do
    # The distinction is the whole point: a connection blip must be redelivered, not dropped.
    capture_log(fn ->
      assert :retry =
               MessageCreatedConsumer.commit_decision(
                 {:error, %DBConnection.ConnectionError{message: "pool timeout"}},
                 0
               )
    end)
  end

  test "applied and duplicate both commit" do
    assert :commit = MessageCreatedConsumer.commit_decision({:ok, :applied}, 0)
    assert :commit = MessageCreatedConsumer.commit_decision({:ok, :duplicate}, 0)
  end

  test "a structurally invalid event commits (skips), never redelivers forever" do
    capture_log(fn ->
      assert :commit = MessageCreatedConsumer.commit_decision({:error, :invalid_event}, 0)
    end)
  end
end
