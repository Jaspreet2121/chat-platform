defmodule ApiGatewayWeb.CallHistoryPresentationTest do
  @moduledoc """
  How a declined call is PRESENTED in the Calls tab: a direct decline reads "declined" to the callee
  (their action) and "missed" to the caller (the recorded masking rule), with duration 0; a member's
  group decline reads "declined" to them with duration 0 while everyone else sees the call's
  outcome. The row shape is unchanged (key-set pinned).
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.CallController

  @caller "22222222-2222-4222-8222-222222222222"
  @callee "33333333-3333-4333-8333-333333333333"
  @app "55555555-5555-4555-8555-555555555555"

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer " <> user_id}) when user_id != "",
      do: {:ok, %{user_id: user_id, app_id: "55555555-5555-4555-8555-555555555555"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConvStub do
    @moduledoc false
    def list_calls_for_user(%{"user_id" => user_id}) do
      direct_declined = %{
        id: "d1",
        room_name: "call-d1",
        kind: "direct",
        app_id: "55555555-5555-4555-8555-555555555555",
        caller_id: "22222222-2222-4222-8222-222222222222",
        callee_id: "33333333-3333-4333-8333-333333333333",
        conversation_id: "c1",
        type: "voice",
        status: "declined",
        created_at: "2026-09-15T10:00:00Z",
        answered_at: nil,
        ended_at: "2026-09-15T10:00:20Z",
        duration_seconds: nil,
        e2ee: false,
        e2ee_accepted: nil,
        e2ee_offer: nil,
        participant_status: nil
      }

      group_ended = %{
        direct_declined
        | id: "g1",
          room_name: "call-g1",
          kind: "group",
          callee_id: nil,
          status: "ended",
          answered_at: "2026-09-15T10:00:05Z",
          duration_seconds: 600,
          participant_status:
            if(user_id == "33333333-3333-4333-8333-333333333333", do: "declined", else: "joined")
      }

      {:ok, %{calls: [direct_declined, group_ended], next_cursor: nil}}
    end
  end

  defmodule UserStub do
    @moduledoc false
    def get_public_profile(_attrs), do: {:error, :profile_invalid}
  end

  setup do
    keys = [:auth_client_adapter, :conversation_client_adapter, :user_client_adapter]
    prev = for k <- keys, into: %{}, do: {k, Application.get_env(:shared_infra, k)}
    prev_persist = Application.get_env(:conversation_service, :conversation_persistence)

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)
    Application.put_env(:conversation_service, :conversation_persistence, true)

    on_exit(fn ->
      for {k, v} <- prev do
        if v,
          do: Application.put_env(:shared_infra, k, v),
          else: Application.delete_env(:shared_infra, k)
      end

      if prev_persist,
        do: Application.put_env(:conversation_service, :conversation_persistence, prev_persist),
        else: Application.delete_env(:conversation_service, :conversation_persistence)
    end)

    :ok
  end

  defp list(user_id) do
    conn =
      :get
      |> conn("/api/v1/calls", %{})
      |> put_req_header("authorization", "Bearer #{user_id}")
      |> CallController.index(%{})

    assert conn.status == 200
    Jason.decode!(conn.resp_body)["calls"] |> Map.new(&{&1["id"], &1})
  end

  test "the CALLEE sees the direct decline as declined, duration 0; the CALLER sees missed" do
    callee = list(@callee)
    assert callee["d1"]["status"] == "declined"
    assert callee["d1"]["duration_seconds"] == 0

    caller = list(@caller)
    assert caller["d1"]["status"] == "missed"
    assert caller["d1"]["duration_seconds"] == 0
  end

  test "a GROUP call the viewer declined reads declined to them with duration 0; the joiner sees the call's outcome" do
    decliner = list(@callee)
    assert decliner["g1"]["status"] == "declined"
    assert decliner["g1"]["duration_seconds"] == 0

    joiner = list(@caller)
    assert joiner["g1"]["status"] == "answered"
    assert joiner["g1"]["duration_seconds"] == 600
  end

  test "KEY-SET of a history row is unchanged" do
    row = list(@callee)["d1"]

    assert Map.keys(row) |> Enum.sort() == [
             "answered_at",
             "callee_id",
             "caller_id",
             "conversation_id",
             "counterpart_id",
             "counterpart_name",
             "created_at",
             "duration_seconds",
             "e2ee",
             "e2ee_accepted",
             "ended_at",
             "id",
             "kind",
             "room_name",
             "status",
             "type"
           ]
  end
end
