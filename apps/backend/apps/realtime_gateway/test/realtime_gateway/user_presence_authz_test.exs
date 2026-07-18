defmodule RealtimeGateway.UserPresenceAuthzTest do
  @moduledoc """
  The "authorize EVERY delivery" gate (`forward_if_authorized/3`): a presence transition is forwarded to the
  client ONLY if the viewer may STILL see the target — re-checked per delivery, so a stale subscription (the
  viewer lost the shared conversation, or the target flipped to "nobody") can't keep leaking. This is the fix
  for the subscribe-time-only authorization the privacy review flagged.

  Stubs the authz clients (shares + visibility). The forward is async (Task), so we assert on the message the
  calling process receives (it stands in for the channel process).
  """
  use ExUnit.Case, async: false

  alias RealtimeGateway.UserPresence

  @me "11111111-1111-4111-8111-111111111111"
  @target "22222222-2222-4222-8222-222222222222"

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

  setup do
    start_supervised!(%{id: ConvStub, start: {ConvStub, :start_link, []}})
    start_supervised!(%{id: UserStub, start: {UserStub, :start_link, []}})
    pc = Application.get_env(:shared_infra, :conversation_client_adapter)
    pu = Application.get_env(:shared_infra, :user_client_adapter)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)

    on_exit(fn ->
      restore(:conversation_client_adapter, pc)
      restore(:user_client_adapter, pu)
    end)

    :ok
  end

  defp restore(k, nil), do: Application.delete_env(:shared_infra, k)
  defp restore(k, v), do: Application.put_env(:shared_infra, k, v)

  # A minimal socket stand-in — forward_if_authorized only reads assigns.current_user_id.
  defp socket, do: %{assigns: %{current_user_id: @me}}
  defp payload, do: %{"user_id" => @target, "online" => true, "last_seen_at" => nil}

  test "forwards when the viewer STILL shares a conversation and the target is visible" do
    ConvStub.set(true)
    UserStub.set("contacts")

    UserPresence.forward_if_authorized(socket(), "presence_updated", payload())

    assert_receive {:presence_forward, "presence_updated", %{"user_id" => @target}}, 1000
  end

  test "DROPS the delivery when the viewer NO LONGER shares a conversation (the ex-contact leak fix)" do
    ConvStub.set(false)
    UserStub.set("contacts")

    UserPresence.forward_if_authorized(socket(), "presence_updated", payload())

    refute_receive {:presence_forward, _, _}, 300
  end

  test "DROPS the delivery when the target has since flipped to 'nobody'" do
    ConvStub.set(true)
    UserStub.set("nobody")

    UserPresence.forward_if_authorized(socket(), "presence_updated", payload())

    refute_receive {:presence_forward, _, _}, 300
  end
end
