defmodule ApiGatewayWeb.AdminMatchesReasonTest do
  @moduledoc """
  The Matches reason gate. Every access to dating match history must carry a typed reason and be
  audited — a read you cannot explain afterwards is one nobody should be able to make.

  Two properties, and they are the same property twice: an unexplained request must not reach the
  data, and it must not be recorded as if it had. So the gate runs BEFORE the read, and the audit
  runs before the read too — the audit row and the query are never allowed to disagree about whether
  an access happened.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.AdminMatchesController

  @root "11111111-1111-4111-8111-111111111111"

  defmodule UserStub do
    @moduledoc false
    def admin_list_matches(_attrs) do
      send(:matches_reason_test, :read_happened)
      {:ok, %{matches: [%{id: "m1"}], page: 1, page_size: 50, total: 1, total_pages: 1}}
    end

    def admin_user_matches(_attrs) do
      send(:matches_reason_test, :read_happened)
      {:ok, %{matches: [%{id: "m2"}], page: 1, page_size: 50, total: 1, total_pages: 1}}
    end
  end

  defmodule AuthStub do
    @moduledoc false
    def write_audit(attrs) do
      send(:matches_reason_test, {:audited, attrs})
      {:ok, %{written: true}}
    end
  end

  setup do
    Process.register(self(), :matches_reason_test)

    prev = %{
      user: Application.get_env(:shared_infra, :user_client_adapter),
      auth: Application.get_env(:shared_infra, :auth_client_adapter)
    }

    Application.put_env(:shared_infra, :user_client_adapter, UserStub)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)

    on_exit(fn ->
      for {key, value} <- [user_client_adapter: prev.user, auth_client_adapter: prev.auth] do
        if value,
          do: Application.put_env(:shared_infra, key, value),
          else: Application.delete_env(:shared_infra, key)
      end
    end)

    :ok
  end

  defp call(action, params) do
    :get
    |> conn("/api/v1/admin/matches", params)
    |> put_req_header("user-agent", "AdminConsole/1")
    |> assign(:admin_session, %{
      user_id: @root,
      role: "root",
      permissions: ["users.sensitive.view"]
    })
    |> then(&apply(AdminMatchesController, action, [&1, params]))
  end

  test "a request WITHOUT a reason is refused — and the data is never read" do
    conn = call(:index, %{})

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "admin.reason_required"

    # The point: no read, and no audit row claiming one.
    refute_receive :read_happened, 200
    refute_receive {:audited, _}, 200
  end

  test "a THROWAWAY reason is refused too — 'x' is not a reason" do
    for junk <- ["", "  ", "x", "abc", "       "] do
      conn = call(:index, %{"reason" => junk})
      assert conn.status == 400, "expected #{inspect(junk)} to be refused"
    end

    refute_receive :read_happened, 200
  end

  test "a real reason is accepted, and the access is audited with the reason, IP and agent" do
    conn = call(:index, %{"reason" => "abuse report #4821"})

    assert conn.status == 200
    assert_receive {:audited, audit}, 500
    assert_receive :read_happened, 500

    assert audit["action"] == "matches.view"
    assert audit["target_id"] == "list"
    assert audit["actor_user_id"] == @root
    assert audit["metadata"]["reason"] == "abuse report #4821"
    assert audit["user_agent"] == "AdminConsole/1"
    assert is_binary(audit["ip_address"])
  end

  test "a per-user view is audited against THAT user, not 'list'" do
    conn =
      call(:user_matches, %{
        "id" => "22222222-2222-4222-8222-222222222222",
        "reason" => "safety escalation"
      })

    assert conn.status == 200
    assert_receive {:audited, audit}, 500
    assert audit["target_id"] == "22222222-2222-4222-8222-222222222222"
    assert audit["metadata"]["reason"] == "safety escalation"
  end

  test "the reason is bounded — a 10 KB 'reason' is truncated, not stored whole" do
    conn = call(:index, %{"reason" => String.duplicate("a", 10_000)})

    assert conn.status == 200
    assert_receive {:audited, audit}, 500
    assert String.length(audit["metadata"]["reason"]) == 200
  end
end
