defmodule ApiGatewayWeb.ChecklistControllerTest do
  @moduledoc """
  The checklist mutation surface (126): membership gates both endpoints (MUT-1), the
  `checklist_updated` frame goes to the CONVERSATION topic AFTER the commit carrying the full items
  array (MUT-4), and every domain refusal carries its own code — including the 409 that hands the
  client the item's current state instead of letting it retry blind.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.MessageController

  @conversation "11111111-1111-4111-8111-111111111111"
  @other "99999999-9999-4999-8999-999999999999"
  @member "22222222-2222-4222-8222-222222222222"
  @stranger "33333333-3333-4333-8333-333333333333"
  @message "aaaaaaaa-0000-4000-8000-0000000000aa"

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer member"}),
      do: {:ok, %{user_id: "22222222-2222-4222-8222-222222222222", app_id: "app1"}}

    def current_session(%{"authorization" => "Bearer stranger"}),
      do: {:ok, %{user_id: "33333333-3333-4333-8333-333333333333", app_id: "app1"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConvStub do
    @moduledoc false
    def get_conversation(%{"user_id" => "22222222-2222-4222-8222-222222222222"}),
      do: {:ok, %{conversation_id: "11111111-1111-4111-8111-111111111111"}}

    def get_conversation(_), do: {:error, :conversation_membership_forbidden}
  end

  # Records the write so the frame's ordering can be observed, and answers whatever the test wants.
  defmodule MsgStub do
    @moduledoc false
    def start_link, do: Agent.start_link(fn -> %{written: false} end, name: __MODULE__)
    def written?, do: Agent.get(__MODULE__, & &1.written)

    def tick_checklist_item(attrs) do
      send(self(), {:ticked, attrs})
      reply()
    end

    def add_checklist_item(attrs) do
      send(self(), {:added, attrs})
      reply()
    end

    defp reply do
      Agent.update(__MODULE__, &%{&1 | written: true})

      case Application.get_env(:api_gateway, :checklist_result) do
        nil ->
          {:ok,
           %{
             message_id: "aaaaaaaa-0000-4000-8000-0000000000aa",
             conversation_id: "11111111-1111-4111-8111-111111111111",
             checklist: %{
               items: [
                 %{
                   id: "i1",
                   text: "milk",
                   done: true,
                   done_by: "22222222-2222-4222-8222-222222222222",
                   done_at: "2026-09-18T10:00:00.000000Z"
                 },
                 %{id: "i2", text: "eggs", done: false, done_by: nil, done_at: nil}
               ],
               done_count: 1,
               total: 2
             }
           }}

        result ->
          result
      end
    end
  end

  setup do
    keys = [
      {:shared_infra, :auth_client_adapter},
      {:shared_infra, :conversation_client_adapter},
      {:shared_infra, :message_client_adapter},
      {:api_gateway, :checklist_result},
      {:message_service, :message_persistence}
    ]

    prev = for {app, key} <- keys, into: %{}, do: {{app, key}, Application.get_env(app, key)}

    start_supervised!(%{id: MsgStub, start: {MsgStub, :start_link, []}})
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)
    Application.delete_env(:api_gateway, :checklist_result)
    Application.put_env(:message_service, :message_persistence, true)

    on_exit(fn ->
      for {{app, key}, value} <- prev do
        if value == nil,
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end
    end)

    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "conversation:#{@conversation}")
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "conversation:#{@other}")
    :ok
  end

  defp tick(bearer, params \\ %{}) do
    :patch
    |> conn("/x", %{})
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> MessageController.tick_checklist_item(
      Map.merge(
        %{
          "conversation_id" => @conversation,
          "message_id" => @message,
          "item_id" => "i1",
          "done" => true,
          "if_unchanged_since" => nil
        },
        params
      )
    )
  end

  defp add(bearer, text \\ "bread") do
    :post
    |> conn("/x", %{})
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> MessageController.add_checklist_item(%{
      "conversation_id" => @conversation,
      "message_id" => @message,
      "text" => text
    })
  end

  test "the FRAME: checklist_updated on the CONVERSATION topic, full items array, key-set pinned" do
    conn = tick("member")
    assert conn.status == 200

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "conversation:" <> @conversation,
      event: "checklist_updated",
      payload: payload
    }

    assert Map.keys(payload) |> Enum.sort() ==
             [:conversation_id, :done_count, :items, :message_id, :total]

    assert payload.message_id == @message
    assert payload.done_count == 1
    assert payload.total == 2
    assert length(payload.items) == 2
    assert Enum.at(payload.items, 0).done_by == @member

    # The response carries the same aggregate.
    body = Jason.decode!(conn.resp_body)
    assert body["message_id"] == @message
    assert body["checklist"]["done_count"] == 1

    # And NOT to some other conversation's topic.
    refute_receive %Phoenix.Socket.Broadcast{topic: "conversation:" <> @other}, 100
  end

  test "MUT-4 guard: the frame is emitted AFTER the write" do
    refute MsgStub.written?()
    tick("member")
    assert_receive %Phoenix.Socket.Broadcast{event: "checklist_updated"}
    assert MsgStub.written?()
  end

  test "MUT-1 guard: a NON-MEMBER is refused on both endpoints, and nothing is broadcast" do
    conn = tick("stranger")
    assert conn.status == 403
    refute_receive %Phoenix.Socket.Broadcast{event: "checklist_updated"}, 100
    refute_received {:ticked, _}

    conn = add("stranger")
    assert conn.status == 403
    refute_receive %Phoenix.Socket.Broadcast{event: "checklist_updated"}, 100
    refute_received {:added, _}
  end

  test "the token's ABSENCE is distinguishable from null on the wire" do
    tick("member", %{"if_unchanged_since" => nil})
    assert_received {:ticked, with_null}
    assert with_null["if_unchanged_since_given"] == true
    assert with_null["if_unchanged_since"] == nil

    # A params map with no such key at all.
    :patch
    |> conn("/x", %{})
    |> put_req_header("authorization", "Bearer member")
    |> MessageController.tick_checklist_item(%{
      "conversation_id" => @conversation,
      "message_id" => @message,
      "item_id" => "i1",
      "done" => true
    })

    assert_received {:ticked, without}
    assert without["if_unchanged_since_given"] == false
  end

  test "409 checklist.stale carries the item's CURRENT state" do
    Application.put_env(
      :api_gateway,
      :checklist_result,
      {:error, :checklist_stale,
       %{id: "i1", done: true, done_by: @member, done_at: "2026-09-18T10:00:00.000000Z"}}
    )

    conn = tick("member")
    assert conn.status == 409

    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "checklist.stale"
    assert body["item"]["done"] == true
    assert body["item"]["done_by"] == @member
    assert body["item"]["done_at"] == "2026-09-18T10:00:00.000000Z"

    refute_receive %Phoenix.Socket.Broadcast{event: "checklist_updated"}, 100
  end

  test "MUT-2 guard (gateway half): not_allowed is 403 with its own code, not the membership 403" do
    Application.put_env(:api_gateway, :checklist_result, {:error, :checklist_not_allowed})

    conn = tick("member")
    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "checklist.not_allowed"
    refute_receive %Phoenix.Socket.Broadcast{event: "checklist_updated"}, 100
  end

  test "the CAPS carry their own 422 codes" do
    Application.put_env(:api_gateway, :checklist_result, {:error, :checklist_too_many_items})
    conn = add("member")
    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "checklist.too_many_items"

    Application.put_env(:api_gateway, :checklist_result, {:error, :checklist_text_too_long})
    conn = add("member")
    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "checklist.text_too_long"
  end

  test "every outcome logs" do
    log = capture_log([level: :info], fn -> tick("member") end)
    assert log =~ "checklist ticked message=#{@message} item=i1 done=1/2 by=#{@member}"

    Application.put_env(:api_gateway, :checklist_result, {:error, :checklist_not_allowed})
    log = capture_log([level: :info], fn -> tick("member") end)
    assert log =~ "checklist skipped message=#{@message} reason=not_allowed"

    Application.put_env(
      :api_gateway,
      :checklist_result,
      {:error, :checklist_stale, %{id: "i1", done: true, done_by: nil, done_at: nil}}
    )

    log = capture_log([level: :info], fn -> tick("member") end)
    assert log =~ "checklist skipped message=#{@message} reason=stale"

    Application.put_env(:api_gateway, :checklist_result, {:error, :checklist_too_many_items})
    log = capture_log([level: :info], fn -> add("member") end)
    assert log =~ "checklist skipped message=#{@message} reason=caps"

    log = capture_log([level: :warning], fn -> tick("stranger") end)
    _ = log
  end
end
