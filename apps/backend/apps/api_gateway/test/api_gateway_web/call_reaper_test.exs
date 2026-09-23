defmodule ApiGatewayWeb.CallReaperTest do
  @moduledoc """
  The dead-timer backstop (130-group): claims one 60 s slot per node, reads the stale ringing
  group calls, and finishes each one with the SAME handler the timer would have run
  (CallSignaling.group_ring_timeout/2), endpoint standing in for the socket. Store stubbed; the
  broadcast is observed on the endpoint's PubSub.
  """
  use ExUnit.Case, async: false

  alias ApiGatewayWeb.CallReaper

  @stale "11111111-1111-4111-8111-111111111111"
  @member "22222222-2222-4222-8222-222222222222"

  defmodule Store do
    @moduledoc false
    def start_link, do: Agent.start_link(fn -> %{reads: 0, missed: []} end, name: __MODULE__)
    def reads, do: Agent.get(__MODULE__, & &1.reads)
    def missed, do: Agent.get(__MODULE__, & &1.missed)

    def list_stale_ringing_group_calls(%{"older_than_seconds" => secs}) when is_integer(secs) do
      Agent.update(__MODULE__, &%{&1 | reads: &1.reads + 1})
      send(:call_reaper_test, {:stale_read, secs})
      {:ok, %{call_ids: ["11111111-1111-4111-8111-111111111111"]}}
    end

    def mark_group_participants_missed(%{"call_id" => id}) do
      Agent.update(__MODULE__, &%{&1 | missed: &1.missed ++ [id]})
      {:ok, %{call: %{id: id, status: "missed"}, participants: []}}
    end

    def get_call_with_participants(%{"call_id" => id}),
      do:
        {:ok,
         %{
           call: %{id: id, status: "missed"},
           participants: [%{user_id: "22222222-2222-4222-8222-222222222222", status: "missed"}]
         }}
  end

  setup do
    Process.register(self(), :call_reaper_test)
    start_supervised!(%{id: Store, start: {Store, :start_link, []}})
    prev = Application.get_env(:shared_infra, :conversation_client_adapter)
    Application.put_env(:shared_infra, :conversation_client_adapter, Store)
    CallReaper.reset_guard()

    on_exit(fn ->
      CallReaper.reset_guard()

      if prev,
        do: Application.put_env(:shared_infra, :conversation_client_adapter, prev),
        else: Application.delete_env(:shared_infra, :conversation_client_adapter)
    end)

    :ok
  end

  test "reap_now finishes each stale call the way its timer would: missed rows + call:group_ended" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:" <> @member)

    assert CallReaper.reap_now() == [@stale]
    assert Store.missed() == [@stale]

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "call:group_ended",
                     payload: %{call_id: @stale}
                   },
                   1000
  end

  test "the cutoff is the ring window plus slack — and it is what the store is asked for" do
    assert CallReaper.cutoff_seconds() ==
             div(RealtimeGateway.CallSignaling.ring_timeout_ms(), 1000) + 25

    CallReaper.reap_now()
    assert_receive {:stale_read, secs}, 500
    assert secs == CallReaper.cutoff_seconds()
  end

  test "maybe_reap claims ONE slot per interval: many requests, one store read" do
    for _ <- 1..5, do: CallReaper.maybe_reap()
    # The claimed run is a Task; give it a moment, then prove the other four never read.
    assert_receive {:stale_read, _}, 1000
    refute_receive {:stale_read, _}, 300
    assert Store.reads() == 1
  end
end
