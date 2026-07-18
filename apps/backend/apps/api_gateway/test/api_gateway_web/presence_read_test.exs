defmodule ApiGatewayWeb.PresenceReadTest do
  @moduledoc """
  The snapshot read: one entry per target, privacy-filtered per caller, FAIL-CLOSED to "offline" for a target
  the caller may not see. Stubs the Presence store (online/last_seen) and the authz clients (shares +
  visibility). No DB / Redis.
  """
  use ExUnit.Case, async: false

  alias ApiGatewayWeb.PresenceRead

  @caller "cccc1111-1111-4111-8111-111111111111"
  @visible "1111aaaa-1111-4111-8111-111111111111"
  @hidden "2222bbbb-2222-4222-8222-222222222222"

  defmodule PresenceStub do
    @behaviour SharedInfra.Presence
    @impl true
    def mark_online(_), do: :already_online
    @impl true
    def clear_online(_, _), do: :ok
    # @visible is online; everyone else offline with a last_seen.
    @impl true
    def online?("1111aaaa-1111-4111-8111-111111111111"), do: true
    def online?(_), do: false
    @impl true
    def last_seen(_), do: 1_700_000_000
  end

  # @visible shares + is "contacts"; @hidden shares but is "nobody" → not visible.
  defmodule ConvStub do
    def shares_conversation?(%{"user_b" => _}), do: {:ok, %{shares: true}}
  end

  defmodule UserStub do
    def last_seen_visibility(%{"user_id" => "2222bbbb-2222-4222-8222-222222222222"}),
      do: {:ok, %{last_seen_visibility: "nobody"}}

    def last_seen_visibility(_), do: {:ok, %{last_seen_visibility: "contacts"}}
  end

  setup do
    prev = %{
      p: Application.get_env(:shared_infra, :presence_adapter),
      c: Application.get_env(:shared_infra, :conversation_client_adapter),
      u: Application.get_env(:shared_infra, :user_client_adapter)
    }

    Application.put_env(:shared_infra, :presence_adapter, PresenceStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)

    on_exit(fn ->
      put(:presence_adapter, prev.p)
      put(:conversation_client_adapter, prev.c)
      put(:user_client_adapter, prev.u)
    end)

    :ok
  end

  defp put(key, nil), do: Application.delete_env(:shared_infra, key)
  defp put(key, v), do: Application.put_env(:shared_infra, key, v)

  test "a VISIBLE online contact → online: true, no last_seen (they're here now)" do
    [entry] = PresenceRead.snapshot(@caller, [@visible])
    assert entry == %{user_id: @visible, online: true, last_seen_at: nil}
  end

  test "a HIDDEN user (visibility nobody) → fail-closed to offline, no last_seen (indistinguishable)" do
    [entry] = PresenceRead.snapshot(@caller, [@hidden])
    assert entry == %{user_id: @hidden, online: false, last_seen_at: nil}
  end

  test "one entry per requested id, order preserved, deduped" do
    entries = PresenceRead.snapshot(@caller, [@visible, @hidden, @visible])
    assert Enum.map(entries, & &1.user_id) == [@visible, @hidden]
  end

  test "parse_ids handles comma-separated and list forms" do
    assert PresenceRead.parse_ids("a,b, c") == ["a", "b", "c"]
    assert PresenceRead.parse_ids(["a", "b"]) == ["a", "b"]
    assert PresenceRead.parse_ids(nil) == []
  end
end
