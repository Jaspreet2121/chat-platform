defmodule ApiGatewayWeb.MessageSendRateLimitTest do
  @moduledoc """
  THE MESSAGE SEND LIMIT — 60/minute per user on the REST send path.

  The realtime socket has limited writes at 60/min since the socket-limits slice, but the REST path
  had no limit at all: one valid session in a loop could flood a conversation without bound, and each
  send costs a Scylla write, a Postgres mirror, an inbox fan-out to N recipients, a webhook and a
  push. That made it both the cheapest way to make the platform expensive and the cheapest way to
  harass someone. It also meant the socket limit was bypassable by falling back to HTTP.

  Proves: the limit fires with 429 + Retry-After; a legitimate burst below it does not; the key is
  per-USER (one user's traffic never consumes another's, and rotating CONVERSATIONS does not buy more
  budget); and it FAILS OPEN, because unlike contacts sync this limiter is not the security control.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.MessageController
  alias SharedInfra.RateLimiter

  # Must match @send_rate_limit / @send_rate_window_seconds in MessageController.
  @limit 60
  @window 60

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer " <> user}),
      do: {:ok, %{user_id: user, app_id: "app-1"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConvStub do
    @moduledoc false
    def get_conversation(_attrs), do: {:ok, %{conversation_id: "c-1"}}
    # The inbox fan-out runs after a successful send; stubbed so it stays silent.
    def inbox_rows(_attrs), do: {:ok, %{rows: []}}
    def get_participants(_attrs), do: {:ok, %{participants: []}}
    def authorize_send(_attrs), do: {:ok, %{delivery: "deliver"}}
  end

  defmodule MessageStub do
    @moduledoc false
    def create_message(_attrs), do: {:ok, %{message_id: "m-1", status: "sent"}}
  end

  setup do
    keys = [
      :auth_client_adapter,
      :conversation_client_adapter,
      :message_client_adapter,
      :rate_limiter_adapter
    ]

    prev = for k <- keys, into: %{}, do: {k, Application.get_env(:shared_infra, k)}
    prev_persist = Application.get_env(:message_service, :message_persistence)

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :message_client_adapter, MessageStub)
    Application.put_env(:shared_infra, :rate_limiter_adapter, RateLimiter.InMemoryAdapter)
    Application.put_env(:message_service, :message_persistence, true)

    start_in_memory_adapter!()
    RateLimiter.InMemoryAdapter.reset()

    on_exit(fn ->
      RateLimiter.InMemoryAdapter.reset()

      for {k, v} <- prev do
        if v, do: Application.put_env(:shared_infra, k, v), else: Application.delete_env(:shared_infra, k)
      end

      if prev_persist,
        do: Application.put_env(:message_service, :message_persistence, prev_persist),
        else: Application.delete_env(:message_service, :message_persistence)
    end)

    :ok
  end

  test "a legitimate burst below the limit is never throttled" do
    # ~2x a fast typist, and the size of a reconnect/outbox flush. A human must never see this.
    for n <- 1..@limit do
      refute send_message("u-burst").status == 429, "message #{n} should not be rate limited"
    end
  end

  test "over the limit → 429 with Retry-After and the uniform envelope" do
    for _ <- 1..@limit, do: send_message("u-flood")

    conn = send_message("u-flood")

    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") == [Integer.to_string(@window)]
    assert %{"error" => %{"code" => "message.rate_limited"}} = Jason.decode!(conn.resp_body)
  end

  test "SCOPING: one user's traffic never consumes another's budget" do
    for _ <- 1..(@limit + 1), do: send_message("u-noisy")
    assert send_message("u-noisy").status == 429

    # Without per-user keying, one flooder would mute everyone — a denial of service built out of the
    # anti-flood control.
    refute send_message("u-quiet").status == 429
  end

  test "PER-USER, NOT PER-CONVERSATION: rotating conversations buys no extra budget" do
    # The whole reason the key is the user. A per-conversation limit is defeated by a loop that
    # changes conversation each send, which is also the harassment shape that matters most.
    for n <- 1..@limit, do: send_message("u-rotator", "conversation-#{n}")

    assert send_message("u-rotator", "conversation-fresh").status == 429
  end

  test "FAIL-OPEN: a limiter outage does not stop people sending messages" do
    # Deliberately the opposite of contacts sync and broadcast send. Here the limiter is an abuse and
    # cost guard, not the security control (membership and authorize_send are, and they still run), so
    # blocking every send in the system on a Redis blip would do more damage than skipping the guard.
    Application.put_env(:shared_infra, :rate_limiter_adapter, RateLimiter.RedisQueryPlanAdapter)

    conn = send_message("u-outage")

    refute conn.status == 429
    refute conn.status == 503
  end

  defp send_message(user, conversation_id \\ "c-1") do
    :post
    |> conn("/x", %{})
    |> put_req_header("authorization", "Bearer " <> user)
    |> MessageController.create(%{
      "conversation_id" => conversation_id,
      "message_type" => "text",
      "body" => "hello"
    })
  end

  defp start_in_memory_adapter! do
    case RateLimiter.InMemoryAdapter.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end
end
