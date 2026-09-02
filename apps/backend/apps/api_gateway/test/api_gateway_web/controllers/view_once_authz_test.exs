defmodule ApiGatewayWeb.ViewOnceStateStub do
  @moduledoc false
  # Message client whose view-once answer the test dictates. Everything else behaves as the ordinary
  # oracle so the agreement property below compares like with like.
  def put_state(state), do: :persistent_term.put({__MODULE__, :state}, state)
  defp state, do: :persistent_term.get({__MODULE__, :state}, :not_view_once)

  def view_once_state(_attrs) do
    case state() do
      # A FAILING PROBE, not a state. The gate must treat this as "not view-once" and let ordinary
      # media through — see the agreement property.
      :error -> {:error, :message_unavailable}
      # A probe that RAISES. This is what an older message client, a partial double, or a
      # mid-deploy release skew actually looks like — a missing callback raises
      # UndefinedFunctionError, it does not return an error tuple. Caught only after 29 real
      # suites went red; the original stub implemented the callback, so the property could not
      # see it.
      :raise -> raise "view_once_state is not implemented by this adapter"
      other -> {:ok, %{state: Atom.to_string(other)}}
    end
  end

  # The ordinary owner-anchored oracle: @member may read @owner's media, nobody else.
  def media_download_allowed(%{"owner_user_id" => owner, "viewer_user_id" => viewer}) do
    {:ok, %{allowed: owner == "owner-1" and viewer == "member-1"}}
  end

  def status_media_allowed(_attrs), do: {:ok, %{allowed: false}}
end

defmodule ApiGatewayWeb.ViewOnceAuthzTest do
  @moduledoc """
  The view-once download gate (115), and — the centerpiece — THE AGREEMENT PROPERTY.

  The gate runs before the purpose dispatch for every media download in the system, so the risk it
  introduces is not "view-once behaves wrongly" but "ordinary media stops working". The property
  below is the whole safety argument: for any media NOT referenced by a view_once message, the
  authorization outcome is identical to what it was before this feature existed — including when the
  view-once probe itself fails.
  """
  use ExUnit.Case, async: false

  alias ApiGatewayWeb.MediaAuthz
  alias ApiGatewayWeb.ViewOnceStateStub

  @owner "owner-1"
  @member "member-1"
  @stranger "stranger-1"
  @media "media-1"

  setup do
    previous = Application.get_env(:shared_infra, :message_client_adapter)
    Application.put_env(:shared_infra, :message_client_adapter, ViewOnceStateStub)
    ViewOnceStateStub.put_state(:not_view_once)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shared_infra, :message_client_adapter, previous),
        else: Application.delete_env(:shared_infra, :message_client_adapter)
    end)

    :ok
  end

  defp asset(purpose \\ "message"),
    do: %{purpose: purpose, owner_user_id: @owner, conversation_id: nil}

  describe "the view-once gate" do
    test "PRE-OPEN: a recipient may still download" do
      ViewOnceStateStub.put_state(:unopened)

      assert MediaAuthz.authorize_download(@media, asset(), @member) == :ok
    end

    test "POST-OPEN: the same recipient is denied" do
      ViewOnceStateStub.put_state(:opened)

      assert MediaAuthz.authorize_download(@media, asset(), @member) == {:error, :not_a_member}
    end

    test "SENDER: denied even though they own the asset" do
      # The reason this gate cannot live inside authorize_message_media/3: there the owner
      # short-circuit fires first, and the sender IS the owner, so the deny would be dead code.
      ViewOnceStateStub.put_state(:sender)

      assert MediaAuthz.authorize_download(@media, asset(), @owner) == {:error, :not_a_member}
    end

    test "EXPIRED: denied after the window, even unopened" do
      ViewOnceStateStub.put_state(:expired)

      assert MediaAuthz.authorize_download(@media, asset(), @member) == {:error, :not_a_member}
    end

    test "an unopened view-once still respects the ORDINARY rule underneath" do
      # The gate ADDS a restriction; it never grants access. A stranger who fails the oracle is
      # denied whether or not the message is view-once.
      ViewOnceStateStub.put_state(:unopened)

      assert MediaAuthz.authorize_download(@media, asset(), @stranger) == {:error, :not_a_member}
    end
  end

  describe "THE AGREEMENT PROPERTY — ordinary media is untouched" do
    # Every fixture the ordinary path can see, run through the gate. Each must produce exactly what
    # the purpose dispatch alone produces.
    @fixtures [
      {"message", @owner, :ok},
      {"message", @member, :ok},
      {"message", @stranger, {:error, :not_a_member}},
      {"user_asset", @owner, :ok},
      {"user_asset", @member, :ok},
      {"user_asset", @stranger, {:error, :not_a_member}},
      {"user_avatar", @stranger, :ok},
      {"sealed_media", @owner, :ok},
      {"sealed_media", @stranger, {:error, :not_a_member}},
      {"group_avatar", @stranger, {:error, :not_a_member}},
      {"status", @stranger, {:error, :not_a_member}},
      {"nonsense_purpose", @stranger, {:error, :not_a_member}}
    ]

    test "not-view-once media behaves exactly as before, for every purpose and viewer" do
      ViewOnceStateStub.put_state(:not_view_once)

      for {purpose, viewer, expected} <- @fixtures do
        assert MediaAuthz.authorize_download(@media, asset(purpose), viewer) == expected,
               "#{purpose}/#{viewer} changed under the view-once gate"
      end
    end

    test "A BROKEN PROBE MUST NOT DENY ORDINARY MEDIA — identical outcomes when the gate errors" do
      # THE ONE THAT MATTERS. This gate sits in front of every download in the system. If a failing
      # probe denied, one bad query or an unreachable message service would become a total media
      # outage. It must fail OPEN, because it is an extra restriction on a narrow feature and not a
      # new dependency for everything else.
      ViewOnceStateStub.put_state(:error)

      for {purpose, viewer, expected} <- @fixtures do
        assert MediaAuthz.authorize_download(@media, asset(purpose), viewer) == expected,
               "#{purpose}/#{viewer} changed when the view-once probe FAILED"
      end
    end

    test "A RAISING PROBE MUST NOT DENY ORDINARY MEDIA EITHER" do
      # The failure mode an error-tuple fallback misses entirely: a client without the callback
      # raises. Every media download in the system routes through this gate, so one missing callback
      # would otherwise 404 all of them.
      ViewOnceStateStub.put_state(:raise)

      for {purpose, viewer, expected} <- @fixtures do
        assert MediaAuthz.authorize_download(@media, asset(purpose), viewer) == expected,
               "#{purpose}/#{viewer} changed when the view-once probe RAISED"
      end

      base = %{"media_id" => @media}
      assert MediaAuthz.put_download_ttl(base, @media, @member) == base
    end

    test "the presign ceiling is added ONLY for view-once media" do
      base = %{"media_id" => @media, "app_id" => "app-1"}

      ViewOnceStateStub.put_state(:not_view_once)
      assert MediaAuthz.put_download_ttl(base, @media, @member) == base

      ViewOnceStateStub.put_state(:error)
      assert MediaAuthz.put_download_ttl(base, @media, @member) == base

      ViewOnceStateStub.put_state(:unopened)
      assert MediaAuthz.put_download_ttl(base, @media, @member)["url_expires_seconds"] == 120
    end
  end
end
