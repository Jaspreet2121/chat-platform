defmodule ApiGatewayWeb.AdminEventOutboxTest do
  @moduledoc """
  The event-outbox ops controller's gates and shapes, no DB: the controller is invoked as a Plug
  (so its RequirePermission plugs actually run), with the MessageClient stubbed at the adapter
  seam. The permission split is the recorded reuse: webhooks.view for reads INCLUDING the
  envelope-carrying expand (the expand is the visibility gate, not a higher permission);
  webhooks.manage for the one-way acknowledge.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.AdminEventOutboxController

  defmodule MsgStub do
    @moduledoc false
    def event_outbox_summary(_attrs),
      do:
        {:ok,
         %{
           staged: %{count: 0, max_age_seconds: 0},
           pending: %{count: 1, max_age_seconds: 42},
           aborted: %{count: 2},
           acknowledged: %{count: 3}
         }}

    def event_outbox_list(attrs),
      do: {:ok, %{items: [%{id: "row-1", status: attrs["status"]}], count: 1, next_cursor: nil}}

    def event_outbox_get(%{"id" => "missing"}), do: {:error, :event_not_found}

    def event_outbox_get(%{"id" => id}),
      do: {:ok, %{id: id, envelope: %{"payload" => %{"message_id" => "m1"}}}}

    def event_outbox_acknowledge(%{"id" => "not-aborted"}),
      do: {:ok, %{id: "not-aborted", status: "noop"}}

    def event_outbox_acknowledge(%{"id" => id}), do: {:ok, %{id: id, status: "acknowledged"}}
  end

  setup do
    previous = Application.get_env(:shared_infra, :message_client_adapter)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shared_infra, :message_client_adapter, previous),
        else: Application.delete_env(:shared_infra, :message_client_adapter)
    end)

    :ok
  end

  defp call(action, role, params \\ %{}) do
    conn =
      :post
      |> conn("/", params)
      |> Map.put(:params, params)

    conn =
      if role do
        assign(conn, :admin_session, %{
          user_id: "admin-1",
          role: role,
          permissions: SharedInfra.IAM.permissions_for(role)
        })
      else
        conn
      end

    AdminEventOutboxController.call(conn, AdminEventOutboxController.init(action))
  end

  test "(a) reads ride webhooks.view: support sees summary/rows/expand; moderator and no-session are 403" do
    assert %{status: 200} = call(:summary, "support")
    assert %{status: 200} = call(:index, "support", %{"status" => "aborted"})
    # The envelope-carrying expand is a READ — same permission as the lists, by decision.
    assert %{status: 200} = call(:show, "support", %{"id" => "row-1"})

    assert %{status: 403, halted: true} = call(:summary, "moderator")
    assert %{status: 403, halted: true} = call(:show, "moderator", %{"id" => "row-1"})
    assert %{status: 403, halted: true} = call(:summary, nil)
  end

  test "(a2) acknowledge rides webhooks.manage: admin yes, support no" do
    assert %{status: 200} = call(:acknowledge, "admin", %{"id" => "row-1"})
    assert %{status: 403, halted: true} = call(:acknowledge, "support", %{"id" => "row-1"})
  end

  test "shapes: summary passes through; list wraps {data,count,next_cursor}; noop is 409" do
    summary = call(:summary, "admin")
    assert summary.status == 200
    assert Jason.decode!(summary.resp_body)["aborted"]["count"] == 2

    listing = call(:index, "admin", %{"status" => "pending"})
    body = Jason.decode!(listing.resp_body)
    assert body["count"] == 1
    assert [%{"id" => "row-1"}] = body["data"]

    missing = call(:show, "admin", %{"id" => "missing"})
    assert missing.status == 404

    noop = call(:acknowledge, "admin", %{"id" => "not-aborted"})
    assert noop.status == 409
  end
end
