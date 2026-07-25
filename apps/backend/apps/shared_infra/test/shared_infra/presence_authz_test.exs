defmodule SharedInfra.PresenceAuthzTest do
  @moduledoc """
  The presence visibility rule: a viewer may see a target iff they SHARE a conversation AND the target's
  `last_seen_visibility` is not "nobody" — FAIL-CLOSED on both. This is the single security gate (subscribe +
  read use it), so its edges are the ones that matter: a wrong "true" leaks presence against the user's wishes.

  Stubs the ConversationClient (shares) and UserClient (visibility) via config — no DB.
  """
  use ExUnit.Case, async: false

  alias SharedInfra.PresenceAuthz

  @viewer "11111111-1111-4111-8111-111111111111"
  @target "22222222-2222-4222-8222-222222222222"

  defmodule ConvStub do
    def start_link, do: Agent.start_link(fn -> %{shares: true, blocked: false, error: false} end, name: __MODULE__)
    def set(key, v), do: Agent.update(__MODULE__, &Map.put(&1, key, v))
    def shares_conversation?(_attrs) do
      s = Agent.get(__MODULE__, & &1)
      if s.error, do: {:error, :conversation_unavailable}, else: {:ok, %{shares: s.shares}}
    end

    def either_blocked?(_attrs), do: {:ok, %{blocked: Agent.get(__MODULE__, & &1.blocked)}}
  end

  defmodule UserStub do
    def start_link, do: Agent.start_link(fn -> %{visibility: "contacts", error: false} end, name: __MODULE__)
    def set(key, v), do: Agent.update(__MODULE__, &Map.put(&1, key, v))
    def last_seen_visibility(_attrs) do
      s = Agent.get(__MODULE__, & &1)
      if s.error, do: {:error, :user_unavailable}, else: {:ok, %{last_seen_visibility: s.visibility}}
    end
  end

  setup do
    start_supervised!(%{id: ConvStub, start: {ConvStub, :start_link, []}})
    start_supervised!(%{id: UserStub, start: {UserStub, :start_link, []}})
    prev_conv = Application.get_env(:shared_infra, :conversation_client_adapter)
    prev_user = Application.get_env(:shared_infra, :user_client_adapter)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)

    on_exit(fn ->
      restore(:conversation_client_adapter, prev_conv)
      restore(:user_client_adapter, prev_user)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, v), do: Application.put_env(:shared_infra, key, v)

  test "shared conversation + visibility 'contacts' → CAN see" do
    UserStub.set(:visibility, "contacts")
    ConvStub.set(:shares, true)
    assert PresenceAuthz.can_see?(@viewer, @target)
  end

  test "visibility 'everyone' STILL requires a shared conversation (per the product rule)" do
    UserStub.set(:visibility, "everyone")
    ConvStub.set(:shares, false)
    refute PresenceAuthz.can_see?(@viewer, @target)

    ConvStub.set(:shares, true)
    assert PresenceAuthz.can_see?(@viewer, @target)
  end

  test "visibility 'nobody' → NEVER, even with a shared conversation" do
    UserStub.set(:visibility, "nobody")
    ConvStub.set(:shares, true)
    refute PresenceAuthz.can_see?(@viewer, @target)
  end

  test "no shared conversation → cannot see (even 'contacts')" do
    UserStub.set(:visibility, "contacts")
    ConvStub.set(:shares, false)
    refute PresenceAuthz.can_see?(@viewer, @target)
  end

  test "FAIL-CLOSED: a visibility read error → cannot see" do
    UserStub.set(:error, true)
    ConvStub.set(:shares, true)
    refute PresenceAuthz.can_see?(@viewer, @target)
  end

  test "FAIL-CLOSED: a shared-conversation read error → cannot see" do
    UserStub.set(:visibility, "contacts")
    ConvStub.set(:error, true)
    refute PresenceAuthz.can_see?(@viewer, @target)
  end

  test "a BLOCK hides presence — even WITH a shared conversation and visibility 'contacts' (both ways)" do
    UserStub.set(:visibility, "contacts")
    ConvStub.set(:shares, true)
    ConvStub.set(:blocked, true)
    refute PresenceAuthz.can_see?(@viewer, @target)
  end

  test "no block → presence follows the normal shares + visibility rule" do
    UserStub.set(:visibility, "contacts")
    ConvStub.set(:shares, true)
    ConvStub.set(:blocked, false)
    assert PresenceAuthz.can_see?(@viewer, @target)
  end

  test "a user always sees their OWN presence (no gating)" do
    UserStub.set(:visibility, "nobody")
    ConvStub.set(:shares, false)
    assert PresenceAuthz.can_see?(@viewer, @viewer)
  end

  test "nil / empty ids → cannot see" do
    refute PresenceAuthz.can_see?(nil, @target)
    refute PresenceAuthz.can_see?(@viewer, "")
  end
end
