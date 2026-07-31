defmodule ApiGatewayWeb.BroadcastControllerTest do
  @moduledoc """
  Broadcast send (Docker-free; Auth/Conversation/Message clients stubbed). Proves: the fan-out hits the
  SAME create_conversation entry point per recipient and reports per-recipient results; an EXISTING DM's
  conversation_id passes through (reuse, not duplication — the SQL twin is find_or_create_direct's own
  suite); a BLOCKED recipient (authorize_send → drop) is BYTE-indistinguishable from a delivered one in
  the response while its conversation gets NO live broadcast; a mid-list failure doesn't abort the rest
  ("sent to 2 of 3"); the send limiter 429s with retry-after and FAILS CLOSED (503 + retry-after) on
  limiter outage; the per-user single-flight lock 409s a concurrent send (stale locks are reclaimed);
  caps carry {limit}; 401. List storage SQL is ConversationService.BroadcastListsTest.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.BroadcastController

  @me "11111111-1111-4111-8111-111111111111"
  @list "44444444-4444-4444-8444-444444444444"
  # Recipient A: fresh DM. B: EXISTING DM. C: has BLOCKED the sender. D: infra failure.
  @a "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @b "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @c "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  @d "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
  @existing_conv "99999999-9999-4999-8999-999999999999"

  defmodule AuthStub do
    @me "11111111-1111-4111-8111-111111111111"
    def current_session(%{"authorization" => "Bearer me"}),
      do: {:ok, %{user_id: @me, app_id: "app1"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConvStub do
    @b "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    @c "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    @existing_conv "99999999-9999-4999-8999-999999999999"

    def start_link, do: Agent.start_link(fn -> %{members: [], log: []} end, name: __MODULE__)
    def set_members(ids), do: Agent.update(__MODULE__, &Map.put(&1, :members, ids))
    def log, do: Agent.get(__MODULE__, & &1.log) |> Enum.reverse()

    defp record(entry),
      do: Agent.update(__MODULE__, &Map.update!(&1, :log, fn l -> [entry | l] end))

    def get_broadcast_list(%{"owner_user_id" => o, "list_id" => l}) do
      if o == "11111111-1111-4111-8111-111111111111" and
           l == "44444444-4444-4444-8444-444444444444" do
        members = Agent.get(__MODULE__, & &1.members)
        {:ok, %{list_id: l, name: "Friends", member_ids: members, sendable_member_ids: members}}
      else
        {:error, :list_not_found}
      end
    end

    def create_broadcast_list(%{"member_user_ids" => ids}) when length(ids) > 256,
      do: {:error, :member_limit}

    def create_broadcast_list(_attrs),
      do: {:ok, %{list_id: "new-list", name: "L", member_count: 1}}

    # The SAME entry point a normal first message uses: recipient B resolves the EXISTING conversation;
    # everyone else gets a fresh one derived from their id (distinct per recipient).
    def create_conversation(%{"type" => "direct", "participant_user_ids" => [recipient]} = attrs) do
      record({:create_conversation, recipient, attrs["created_by"]})

      if recipient == @b do
        {:ok, %{conversation_id: @existing_conv, type: "direct", existing: true}}
      else
        {:ok,
         %{
           conversation_id: "conv-" <> recipient,
           type: "direct",
           created: true,
           created_by: attrs["created_by"],
           participant_user_ids: [recipient]
         }}
      end
    end

    # Recipient C has blocked the sender → the drop disposition (b3cbd3c).
    def authorize_send(%{"conversation_id" => "conv-" <> @c}),
      do: {:ok, %{authorized: true, delivery: "drop"}}

    def authorize_send(_attrs), do: {:ok, %{authorized: true}}

    # Consumed by the live broadcasts.
    def get_conversation(_attrs), do: {:ok, %{participants: []}}

    def inbox_rows(%{"user_ids" => uids, "conversation_id" => c}),
      do: {:ok, %{rows: Enum.map(uids, &%{user_id: &1, conversation_id: c, unread_count: 0})}}
  end

  defmodule MsgStub do
    @d "dddddddd-dddd-4ddd-8ddd-dddddddddddd"

    # Recipient D's insert blows up (infra failure). A blocked recipient's create returns the SYNTHETIC
    # canonical ack — same shape as a real one (b3cbd3c) — which is what makes the result entry
    # indistinguishable.
    def create_message(%{"conversation_id" => "conv-" <> @d}), do: {:error, :message_unavailable}

    def create_message(attrs) do
      {:ok,
       %{
         message_id: "msg-for-" <> attrs["conversation_id"],
         conversation_id: attrs["conversation_id"]
       }}
    end
  end

  defmodule LimiterDeny do
    @behaviour SharedInfra.RateLimiter
    @impl true
    def check_rate(_attrs), do: {:error, :rate_limited, 42}
  end

  defmodule LimiterDown do
    @behaviour SharedInfra.RateLimiter
    @impl true
    def check_rate(%{"fail_open" => false}), do: {:error, :rate_limiter_unavailable, :down}
    def check_rate(_attrs), do: :ok
  end

  setup do
    start_supervised!(%{id: ConvStub, start: {ConvStub, :start_link, []}})

    prev = %{
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      conv: Application.get_env(:shared_infra, :conversation_client_adapter),
      msg: Application.get_env(:shared_infra, :message_client_adapter),
      limiter: Application.get_env(:shared_infra, :rate_limiter_adapter)
    }

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)

    Application.put_env(
      :shared_infra,
      :rate_limiter_adapter,
      SharedInfra.RateLimiter.InMemoryAdapter
    )

    SharedInfra.RateLimiter.InMemoryAdapter.reset()
    :ets.delete_all_objects(:broadcast_send_locks)

    on_exit(fn ->
      restore(:auth_client_adapter, prev.auth)
      restore(:conversation_client_adapter, prev.conv)
      restore(:message_client_adapter, prev.msg)
      restore(:rate_limiter_adapter, prev.limiter)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  defp authed(token \\ "me") do
    :post |> conn("/x", %{}) |> put_req_header("authorization", "Bearer #{token}")
  end

  defp send!(token \\ "me") do
    BroadcastController.send_broadcast(authed(token), %{
      "list_id" => @list,
      "message_type" => "text",
      "body" => "hello all"
    })
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "fans out per recipient through the SAME create_conversation entry point; existing DM reused" do
    ConvStub.set_members([@a, @b])

    conn = send!()
    assert conn.status == 200

    response = body(conn)
    assert response["sent_count"] == 2
    assert response["failed_count"] == 0

    # One conversation resolve per recipient, all created_by the sender (the normal DM entry point).
    assert ConvStub.log() == [{:create_conversation, @a, @me}, {:create_conversation, @b, @me}]

    results = Map.new(response["results"], &{&1["user_id"], &1})

    # Fresh DM: a per-recipient conversation. EXISTING DM: the pre-existing id, REUSED not duplicated.
    assert results[@a]["conversation_id"] == "conv-" <> @a
    assert results[@b]["conversation_id"] == @existing_conv
    assert results[@a]["message_id"] == "msg-for-conv-" <> @a
  end

  test "a BLOCKED recipient is indistinguishable in the response — and its conversation gets NO live event" do
    ConvStub.set_members([@a, @c])
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@c}")

    conn = send!()
    response = body(conn)

    assert response["sent_count"] == 2

    [entry_a, entry_c] = Enum.sort_by(response["results"], & &1["user_id"])

    # Same status, same key set — nothing distinguishes the drop (the message_id is the synthetic ack).
    assert entry_c["status"] == "sent"
    assert Map.keys(entry_a) == Map.keys(entry_c)
    assert entry_c["message_id"] == "msg-for-conv-" <> @c

    # The blocker's inbox is never woken (the drop skips the :message broadcast).
    refute_receive %Phoenix.Socket.Broadcast{event: "conversation_updated"}, 300
  end

  test "PARTIAL FAILURE: one recipient's infra error doesn't abort the rest — 'sent to 2 of 3'" do
    ConvStub.set_members([@a, @d, @b])

    conn = send!()
    response = body(conn)

    assert response["sent_count"] == 2
    assert response["failed_count"] == 1

    failed = Enum.find(response["results"], &(&1["status"] == "failed"))
    assert failed["user_id"] == @d
    refute Map.has_key?(failed, "message_id")

    # Order preserved; the failure sits between two successes (the loop continued).
    assert Enum.map(response["results"], & &1["status"]) == ["sent", "failed", "sent"]
  end

  test "send limiter: 429 + retry-after when denied; FAIL-CLOSED 503 + retry-after on limiter outage" do
    ConvStub.set_members([@a])

    Application.put_env(:shared_infra, :rate_limiter_adapter, LimiterDeny)
    denied = send!()
    assert denied.status == 429
    assert body(denied)["error"]["code"] == "broadcasts.rate_limited"
    assert get_resp_header(denied, "retry-after") == ["42"]

    Application.put_env(:shared_infra, :rate_limiter_adapter, LimiterDown)
    down = send!()
    assert down.status == 503
    assert body(down)["error"]["code"] == "broadcasts.limiter_unavailable"
    assert get_resp_header(down, "retry-after") == ["30"]
  end

  test "SINGLE-FLIGHT: a concurrent send from the same user → 409; a STALE lock is reclaimed" do
    ConvStub.set_members([@a])

    # A live in-flight lock → 409 send_in_progress.
    :ets.insert(:broadcast_send_locks, {@me, System.system_time(:second)})
    busy = send!()
    assert busy.status == 409
    assert body(busy)["error"]["code"] == "broadcasts.send_in_progress"

    # A lock from a request that died >120s ago is reclaimed — the send proceeds.
    :ets.insert(:broadcast_send_locks, {@me, System.system_time(:second) - 300})
    assert send!().status == 200
    # The lock is released after the fan-out.
    assert :ets.lookup(:broadcast_send_locks, @me) == []
  end

  test "caps carry {limit}; foreign list 404; missing message_type 400; no session 401" do
    over = for i <- 1..257, do: "u-#{i}"

    capped =
      BroadcastController.create(authed(), %{"name" => "Big", "member_user_ids" => over})

    assert capped.status == 400
    assert body(capped)["error"]["code"] == "broadcasts.member_limit"
    assert body(capped)["error"]["limit"] == 256

    foreign =
      BroadcastController.send_broadcast(authed("me"), %{
        "list_id" => "55555555-5555-4555-8555-555555555555",
        "message_type" => "text",
        "body" => "x"
      })

    assert foreign.status == 404

    no_type = BroadcastController.send_broadcast(authed(), %{"list_id" => @list})
    assert no_type.status == 400
    assert body(no_type)["error"]["code"] == "broadcasts.message_invalid"

    assert send!("nobody").status == 401
  end
end
