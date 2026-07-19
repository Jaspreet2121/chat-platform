defmodule ApiGatewayWeb.V1.PresenceReadIdTest do
  @moduledoc """
  The /v1 presence READ has the SAME external↔internal mismatch subscribe had: the SDK sends EXTERNAL ids, but
  authz + the online store are INTERNAL-keyed. This pins the controller's id-bridge — resolve external →
  internal, snapshot on internal, relabel the response back to the EXTERNAL id — and that an unresolvable id
  fails closed to offline under its own external id (no internal uuid ever crosses /v1).
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.V1.PresenceController

  @caller "cccc1111-1111-4111-8111-111111111111"
  @app "55555555-5555-4555-8555-555555555555"
  @bob_internal "22222222-2222-4222-8222-222222222222"

  defmodule AuthStub do
    def resolve_external_user(%{"external_id" => "bob_ext"}),
      do: {:ok, %{user_id: "22222222-2222-4222-8222-222222222222"}}

    def resolve_external_user(_), do: {:error, :not_found}
  end

  defmodule PresenceStub do
    @behaviour SharedInfra.Presence
    @impl true
    def mark_online(_), do: :already_online
    @impl true
    def clear_online(_, _), do: :ok
    @impl true
    def online?("22222222-2222-4222-8222-222222222222"), do: true
    def online?(_), do: false
    @impl true
    def last_seen(_), do: nil
  end

  defmodule ConvStub do
    def shares_conversation?(_), do: {:ok, %{shares: true}}
  end

  defmodule UserStub do
    def last_seen_visibility(_), do: {:ok, %{last_seen_visibility: "contacts"}}
  end

  setup do
    prev = %{
      a: Application.get_env(:shared_infra, :auth_client_adapter),
      p: Application.get_env(:shared_infra, :presence_adapter),
      c: Application.get_env(:shared_infra, :conversation_client_adapter),
      u: Application.get_env(:shared_infra, :user_client_adapter)
    }

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :presence_adapter, PresenceStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)

    on_exit(fn ->
      put(:auth_client_adapter, prev.a)
      put(:presence_adapter, prev.p)
      put(:conversation_client_adapter, prev.c)
      put(:user_client_adapter, prev.u)
    end)

    :ok
  end

  defp put(k, nil), do: Application.delete_env(:shared_infra, k)
  defp put(k, v), do: Application.put_env(:shared_infra, k, v)

  defp v1_conn(user_ids) do
    :get
    |> conn("/v1/presence?user_ids=#{user_ids}")
    |> Map.put(:params, %{"user_ids" => user_ids})
    |> assign(:v1_app_id, @app)
    |> assign(:v1_user_id, @caller)
  end

  test "resolves the EXTERNAL id to internal, reads presence, and relabels back to the EXTERNAL id" do
    conn = PresenceController.index(v1_conn("bob_ext"), %{"user_ids" => "bob_ext"})
    assert conn.status == 200

    %{"presence" => [entry]} = Jason.decode!(conn.resp_body)
    # The response speaks the EXTERNAL id (never @bob_internal), and Bob is online.
    assert entry["user_id"] == "bob_ext"
    assert entry["online"] == true
    refute entry["user_id"] == @bob_internal
  end

  test "an UNRESOLVABLE external id → offline under its own id (fail-closed, no crash)" do
    conn = PresenceController.index(v1_conn("ghost"), %{"user_ids" => "ghost"})
    assert conn.status == 200
    %{"presence" => [entry]} = Jason.decode!(conn.resp_body)
    assert entry == %{"user_id" => "ghost", "online" => false, "last_seen_at" => nil}
  end

  test "an app actor (no v1_user_id) → 403" do
    conn =
      :get
      |> conn("/v1/presence")
      |> assign(:v1_app_id, @app)

    conn = PresenceController.index(conn, %{"user_ids" => "bob_ext"})
    assert conn.status == 403
  end
end
