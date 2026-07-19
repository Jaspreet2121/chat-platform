defmodule RealtimeGateway.UserPresenceAuthzTest do
  @moduledoc """
  The presence id-boundary + the "authorize EVERY delivery" gate.

  TWO id spaces meet here: the SDK speaks the integrator's EXTERNAL id, but topic/authz/store are keyed on the
  INTERNAL uuid. These tests pin the fix for the prod bug where subscribe ALWAYS returned [] (it ran authz on
  the raw external id, which never matched internal-keyed conversation_participants) — and the privacy gate
  that re-authorizes every delivery.

  Stubs the resolver (external↔internal) + the authz clients (shares + visibility).
  """
  use ExUnit.Case, async: false

  alias RealtimeGateway.UserPresence

  @me "11111111-1111-4111-8111-111111111111"
  @target_internal "22222222-2222-4222-8222-222222222222"
  @target_external "bob_p5gb30p8"
  @app "55555555-5555-4555-8555-555555555555"

  defmodule AuthStub do
    # external "bob_p5gb30p8" ↔ internal @target_internal; anything else is unknown.
    def resolve_external_user(%{"external_id" => "bob_p5gb30p8"}),
      do: {:ok, %{user_id: "22222222-2222-4222-8222-222222222222"}}

    def resolve_external_user(_), do: {:error, :not_found}

    def resolve_user_external_id(%{"user_id" => "22222222-2222-4222-8222-222222222222"}),
      do: {:ok, %{external_id: "bob_p5gb30p8"}}

    def resolve_user_external_id(_), do: {:error, :not_found}
  end

  defmodule ConvStub do
    def start_link, do: Agent.start_link(fn -> true end, name: __MODULE__)
    def set(v), do: Agent.update(__MODULE__, fn _ -> v end)
    def shares_conversation?(_), do: {:ok, %{shares: Agent.get(__MODULE__, & &1)}}
  end

  defmodule UserStub do
    def start_link, do: Agent.start_link(fn -> "contacts" end, name: __MODULE__)
    def set(v), do: Agent.update(__MODULE__, fn _ -> v end)
    def last_seen_visibility(_), do: {:ok, %{last_seen_visibility: Agent.get(__MODULE__, & &1)}}
  end

  # A fake endpoint recording subscribe/unsubscribe (topic side-effects); no broadcast used in these tests.
  defmodule FakeEndpoint do
    def subscribe(topic), do: send(self(), {:subscribed, topic})
    def unsubscribe(topic), do: send(self(), {:unsubscribed, topic})
  end

  setup do
    start_supervised!(%{id: ConvStub, start: {ConvStub, :start_link, []}})
    start_supervised!(%{id: UserStub, start: {UserStub, :start_link, []}})
    prev = %{
      a: Application.get_env(:shared_infra, :auth_client_adapter),
      c: Application.get_env(:shared_infra, :conversation_client_adapter),
      u: Application.get_env(:shared_infra, :user_client_adapter)
    }

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)

    on_exit(fn ->
      put(:auth_client_adapter, prev.a)
      put(:conversation_client_adapter, prev.c)
      put(:user_client_adapter, prev.u)
    end)

    :ok
  end

  defp put(k, nil), do: Application.delete_env(:shared_infra, k)
  defp put(k, v), do: Application.put_env(:shared_infra, k, v)

  defp socket,
    do: %Phoenix.Socket{
      assigns: %{current_user_id: @me, app_id: @app, presence_subs: %{}},
      endpoint: FakeEndpoint
    }

  # --- subscribe: the exact prod bug (was always []) ---

  test "THE BUG FIX: subscribe with an EXTERNAL id that shares a conversation → authorized (non-empty)" do
    ConvStub.set(true)
    UserStub.set("contacts")

    {socket, authorized} = UserPresence.subscribe(socket(), [@target_external])

    # Was []; now the external id is resolved to internal, authorized, and returned under the EXTERNAL id.
    assert authorized == [@target_external]
    # Subscribed to the INTERNAL-keyed topic (so the internal-keyed broadcast actually reaches it).
    assert_received {:subscribed, "presence:22222222-2222-4222-8222-222222222222"}
    # presence_subs maps external → internal.
    assert socket.assigns.presence_subs == %{@target_external => @target_internal}
  end

  test "an external id with NO shared conversation → dropped (still fail-closed)" do
    ConvStub.set(false)
    UserStub.set("contacts")

    {socket, authorized} = UserPresence.subscribe(socket(), [@target_external])
    assert authorized == []
    assert socket.assigns.presence_subs == %{}
    refute_received {:subscribed, _}
  end

  test "an UNRESOLVABLE external id → dropped, no crash" do
    {socket, authorized} = UserPresence.subscribe(socket(), ["ghost_who_does_not_exist"])
    assert authorized == []
    assert socket.assigns.presence_subs == %{}
  end

  test "unsubscribe removes by the EXTERNAL id and unsubscribes the INTERNAL topic" do
    ConvStub.set(true)
    {socket, _} = UserPresence.subscribe(socket(), [@target_external])
    socket = UserPresence.unsubscribe(socket, [@target_external])

    assert socket.assigns.presence_subs == %{}
    assert_received {:unsubscribed, "presence:22222222-2222-4222-8222-222222222222"}
  end

  # --- forward: authorize every delivery, on the INTERNAL id, push the EXTERNAL id ---

  defp broadcast_payload,
    do: %{
      "user_id" => @target_external,
      "internal_id" => @target_internal,
      "online" => true,
      "last_seen_at" => nil
    }

  test "forwards when still authorized — and the pushed frame carries the EXTERNAL id, NOT the internal one" do
    ConvStub.set(true)
    UserStub.set("contacts")

    UserPresence.forward_if_authorized(socket(), "presence_updated", broadcast_payload())

    assert_receive {:presence_forward, "presence_updated", pushed}, 1000
    assert pushed["user_id"] == @target_external
    # The internal uuid must NEVER reach the SDK.
    refute Map.has_key?(pushed, "internal_id")
  end

  test "DROPS the delivery when the viewer NO LONGER shares a conversation (ex-contact leak fix)" do
    ConvStub.set(false)
    UserStub.set("contacts")

    UserPresence.forward_if_authorized(socket(), "presence_updated", broadcast_payload())
    refute_receive {:presence_forward, _, _}, 300
  end

  test "DROPS the delivery when the target has since flipped to 'nobody'" do
    ConvStub.set(true)
    UserStub.set("nobody")

    UserPresence.forward_if_authorized(socket(), "presence_updated", broadcast_payload())
    refute_receive {:presence_forward, _, _}, 300
  end
end
