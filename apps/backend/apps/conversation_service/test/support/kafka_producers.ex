defmodule ConversationService.CaptureKafkaProducer do
  @moduledoc false
  # Emission runs in a Task (separate process), so we send to the test pid recorded in app
  # env (set in setup) rather than self(); the test uses assert_receive.
  #
  # LIVES IN test/support ON PURPOSE. It used to be declared at the top of
  # participant_events_test.exs, which meant participant_events_integration_test.exs only passed when
  # that OTHER file happened to be loaded in the same run: alone it referenced an undefined module,
  # the fire-and-forget emit Task died silently, and the assertion timed out with an empty mailbox.
  # That made the suite pass or fail on which files ran together — invisible in an umbrella-wide run,
  # immediate under the per-suite runner. test/support is compiled for :test regardless of run scope.
  @behaviour SharedInfra.Kafka.Producer

  @impl true
  def produce(topic, key, value, _opts \\ []) do
    case Application.get_env(:shared_infra, :capture_test_pid) do
      pid when is_pid(pid) -> send(pid, {:kafka_published, topic, key, value})
      _ -> :ok
    end

    {:ok, :captured}
  end
end

defmodule ConversationService.FailingKafkaProducer do
  @moduledoc false
  @behaviour SharedInfra.Kafka.Producer

  @impl true
  def produce(_topic, _key, _value, _opts \\ []), do: raise("kafka broker is down")
end
