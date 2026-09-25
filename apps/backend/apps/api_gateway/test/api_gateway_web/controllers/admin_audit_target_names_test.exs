defmodule ApiGatewayWeb.AdminAuditTargetNamesTest do
  @moduledoc """
  The audit log names its TARGETS when they are users — "banned @guru", not "banned 7f3a…".

  Only rows whose target_type is "user" are resolved; a matches view carries "list" as its target
  and a content read carries a conversation id, and those must stay exactly as written rather than
  being looked up as if they were people.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  @opts ApiGatewayWeb.Router.init([])

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer root"}),
      do:
        {:ok,
         %{
           user_id: "root-1",
           session_id: "s",
           device_id: "d",
           platform: "web",
           is_admin: true,
           role: "root",
           permissions: SharedInfra.IAM.permissions_for("root")
         }}

    def current_session(_), do: {:error, :session_invalid}

    def list_audit(_attrs),
      do:
        {:ok,
         %{
           page: 1,
           page_size: 50,
           total: 2,
           total_pages: 1,
           entries: [
             %{
               id: "a1",
               actor_user_id: "root-1",
               action: "user.ban",
               target_type: "user",
               target_id: "u-guru"
             },
             %{
               id: "a2",
               actor_user_id: "root-1",
               action: "matches.view",
               target_type: "matches",
               target_id: "list"
             }
           ]
         }}

    def list_user_summaries(%{"user_ids" => ids}) do
      known = %{
        "root-1" => %{
          user_id: "root-1",
          display_name: "Root",
          username: "root",
          phone_number: "+1"
        },
        "u-guru" => %{user_id: "u-guru", display_name: nil, username: "guru", phone_number: "+2"}
      }

      {:ok, %{summaries: ids |> Enum.map(&Map.get(known, &1)) |> Enum.reject(&is_nil/1)}}
    end
  end

  setup do
    previous = Application.get_env(:shared_infra, :auth_client_adapter)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shared_infra, :auth_client_adapter, previous),
        else: Application.delete_env(:shared_infra, :auth_client_adapter)
    end)

    :ok
  end

  test "user targets get a name and handle; non-user targets are left alone; order is kept" do
    conn =
      conn(:get, "/api/v1/admin/audit")
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer root")
      |> ApiGatewayWeb.Router.call(@opts)

    assert conn.status == 200
    %{"entries" => [ban, view]} = Jason.decode!(conn.resp_body)

    assert ban["target_id"] == "u-guru"
    assert ban["target_username"] == "guru"
    assert ban["actor_username"] == "root"

    assert view["target_id"] == "list"
    refute Map.has_key?(view, "target_username")
  end
end
