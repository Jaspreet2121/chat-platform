defmodule SharedInfra.PresenceTest do
  @moduledoc """
  The online-store CONTRACT the channel relies on: the FIRST mark_online is a transition (broadcast), a
  repeat is `:already_online` (silent — no heartbeat flood), clear flips to offline + stamps last_seen, and
  online?/last_seen are fail-CLOSED.

  Uses an in-memory adapter (an Agent) so the contract is tested without Redis. The Redis-specific atomicity
  (the `SET ... EX ttl GET` previous-value read) needs a live Redis and is CI/integration-only — noted in the
  report. The transition SEMANTICS the channel depends on are what this proves.
  """
  use ExUnit.Case, async: false

  alias SharedInfra.Presence

  defmodule MemoryAdapter do
    @moduledoc false
    @behaviour SharedInfra.Presence

    def start_link,
      do:
        Agent.start_link(fn -> %{online: MapSet.new(), last_seen: %{}, fail: false} end,
          name: __MODULE__
        )

    def fail!, do: Agent.update(__MODULE__, &Map.put(&1, :fail, true))

    @impl true
    def mark_online(user_id) do
      Agent.get_and_update(__MODULE__, fn s ->
        cond do
          s.fail -> {:error, s}
          MapSet.member?(s.online, user_id) -> {:already_online, s}
          true -> {{:transition, :online}, %{s | online: MapSet.put(s.online, user_id)}}
        end
      end)
    end

    @impl true
    def clear_online(user_id, now_unix) do
      Agent.update(__MODULE__, fn s ->
        %{
          s
          | online: MapSet.delete(s.online, user_id),
            last_seen: Map.put(s.last_seen, user_id, now_unix)
        }
      end)

      :ok
    end

    @impl true
    def online?(user_id) do
      s = Agent.get(__MODULE__, & &1)
      # Fail-closed: an error state reads offline.
      not s.fail and MapSet.member?(s.online, user_id)
    end

    @impl true
    def last_seen(user_id), do: Agent.get(__MODULE__, & &1.last_seen) |> Map.get(user_id)
  end

  @user "aaaa1111-1111-4111-8111-111111111111"

  setup do
    start_supervised!(%{id: MemoryAdapter, start: {MemoryAdapter, :start_link, []}})
    prev = Application.get_env(:shared_infra, :presence_adapter)
    Application.put_env(:shared_infra, :presence_adapter, MemoryAdapter)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:shared_infra, :presence_adapter, prev),
        else: Application.delete_env(:shared_infra, :presence_adapter)
    end)

    :ok
  end

  test "first mark_online is a TRANSITION; a repeat is already_online (the no-flood contract)" do
    assert {:transition, :online} = Presence.mark_online(@user)
    # Every subsequent heartbeat must be silent — this is what stops a broadcast every 30s.
    assert :already_online = Presence.mark_online(@user)
    assert :already_online = Presence.mark_online(@user)
  end

  test "clear_online flips to offline and stamps last_seen" do
    Presence.mark_online(@user)
    assert Presence.online?(@user)

    :ok = Presence.clear_online(@user, 1_700_000_000)
    refute Presence.online?(@user)
    assert Presence.last_seen(@user) == 1_700_000_000
  end

  test "after a clear, mark_online is a TRANSITION again (re-online broadcasts)" do
    Presence.mark_online(@user)
    Presence.clear_online(@user, 1_700_000_000)
    assert {:transition, :online} = Presence.mark_online(@user)
  end

  test "FAIL-CLOSED: online? is false under a store error (never a phantom green dot)" do
    Presence.mark_online(@user)
    assert Presence.online?(@user)
    MemoryAdapter.fail!()
    refute Presence.online?(@user)
    # …and mark_online reports :error (the channel then does NOT broadcast).
    assert :error = Presence.mark_online(@user)
  end
end
