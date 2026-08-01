defmodule ApiGatewayWeb.InviteJoinRateLimitTest do
  @moduledoc """
  THE PER-CODE JOIN CAP — the first per-RESOURCE limit in this codebase.

  A per-user limit is blind to the attack that matters here: 500 accounts draining one leaked invite
  code are each within their own budget, and the group is flooded anyway. The budget has to belong to
  the CODE, so every joiner spends from the same pot.

  Proves both axes and that they compose: one user joining many codes is stopped by the per-user
  limit; many users joining ONE code are stopped by the per-code limit; and neither consumes the
  other's budget. Plus the fail direction (CLOSED — on this endpoint the limiter IS the security
  control) and that a legitimate rate of joining is untouched.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.InviteLinkController
  alias SharedInfra.RateLimiter

  # Must match the module attributes in InviteLinkController.
  @user_limit 10
  @code_limit 60
  @window 3600

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer " <> user}),
      do: {:ok, %{user_id: user, app_id: "app-1"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  # Records exactly what reaches the limiter. Needed because the query-plan adapter IGNORES fail_open
  # (it errors unconditionally), so a 503 test alone cannot tell fail_open: false from fail_open: true
  # — it passed under both until this was added.
  defmodule CapturingAdapter do
    @moduledoc false
    @behaviour SharedInfra.RateLimiter

    @impl true
    def check_rate(attrs) do
      send(:invite_join_collector, {:rate_check, attrs})
      :ok
    end
  end

  defmodule ConvStub do
    @moduledoc false
    def join_group_invite_link(%{"code" => code}),
      do: {:ok, %{status: "joined", conversation_id: "c-" <> code, role: "member"}}

    def inbox_rows(_attrs), do: {:ok, %{rows: []}}
    def get_participants(_attrs), do: {:ok, %{participants: []}}
  end

  setup do
    keys = [:auth_client_adapter, :conversation_client_adapter, :rate_limiter_adapter]
    prev = for k <- keys, into: %{}, do: {k, Application.get_env(:shared_infra, k)}

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :rate_limiter_adapter, RateLimiter.InMemoryAdapter)

    start_in_memory_adapter!()
    RateLimiter.InMemoryAdapter.reset()

    on_exit(fn ->
      RateLimiter.InMemoryAdapter.reset()

      for {k, v} <- prev do
        if v,
          do: Application.put_env(:shared_infra, k, v),
          else: Application.delete_env(:shared_infra, k)
      end
    end)

    :ok
  end

  test "a legitimate rate of joining is never throttled" do
    # A person joining a handful of groups over an hour, and a group taking on new members steadily.
    for n <- 1..@user_limit do
      refute join("u-normal", "code-#{n}").status == 429, "join #{n} should not be limited"
    end
  end

  test "THE ATTACK: many DISTINCT users draining ONE code are stopped by the per-code cap" do
    # Every one of these callers is a different account making its FIRST join, so each is comfortably
    # inside the per-user limit. Only a budget belonging to the CODE can see this.
    for n <- 1..@code_limit do
      refute join("attacker-#{n}", "leaked").status == 429,
             "join #{n} is within the code's budget"
    end

    conn = join("attacker-fresh", "leaked")

    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") == [Integer.to_string(@window)]
    assert %{"error" => %{"code" => "invite_link.rate_limited"}} = Jason.decode!(conn.resp_body)
  end

  test "the per-USER cap still stops one account joining everything" do
    for n <- 1..@user_limit, do: join("u-greedy", "code-#{n}")

    # A fresh code, well inside ITS budget — refused on the user axis.
    assert join("u-greedy", "code-untouched").status == 429
  end

  test "SCOPING: one code's traffic never consumes another's budget" do
    for n <- 1..@code_limit, do: join("attacker-#{n}", "drained")
    assert join("attacker-fresh", "drained").status == 429

    # A different code is untouched. Without per-code scoping, one drained link would block joining
    # every group in the system.
    refute join("someone", "healthy").status == 429
  end

  test "SCOPING: the two axes do not share a pot" do
    # Burn most of one code's budget with distinct users...
    for n <- 1..(@code_limit - 1), do: join("crowd-#{n}", "busy")

    # ...a user who has joined nothing is still free, and their own budget is intact: they can join
    # several OTHER codes afterwards.
    refute join("u-fresh", "busy").status == 429
    for n <- 1..(@user_limit - 1), do: refute(join("u-fresh", "other-#{n}").status == 429)
  end

  test "THE LINK STAYS ALIVE at the cap — it does not go dormant" do
    for n <- 1..@code_limit, do: join("attacker-#{n}", "popular")
    assert join("attacker-next", "popular").status == 429

    # Recoverability without owner action: the budget is a WINDOW, not a kill switch. Making the link
    # dormant would let anyone who can see a link permanently disable it — a griefing tool aimed at
    # the owner. Draining the counter simulates the window expiring.
    RateLimiter.InMemoryAdapter.reset()

    refute join("late-joiner", "popular").status == 429
  end

  test "the KEY SHAPE and FAIL DIRECTION reaching the limiter are the configured ones" do
    Process.register(self(), :invite_join_collector)
    Application.put_env(:shared_infra, :rate_limiter_adapter, CapturingAdapter)

    join("u-shape", "the-code")

    assert_received {:rate_check, %{"key" => "invite_join:u-shape", "fail_open" => false}}

    # The per-resource key: namespaced under res: so a code id can never collide with a user id in
    # the same keyspace — both are opaque strings, so a collision would be silent.
    assert_received {:rate_check,
                     %{"key" => "res:invite_code:the-code:join", "fail_open" => false}}

    Process.unregister(:invite_join_collector)
  end

  test "FAIL-CLOSED: a limiter outage rejects with 503 rather than reopening mass join" do
    Application.put_env(:shared_infra, :rate_limiter_adapter, RateLimiter.RedisQueryPlanAdapter)

    conn = join("u-any", "some-code")

    assert conn.status == 503
    assert get_resp_header(conn, "retry-after") == ["30"]

    assert %{"error" => %{"code" => "invite_link.limiter_unavailable"}} =
             Jason.decode!(conn.resp_body)
  end

  defp join(user, code) do
    :post
    |> conn("/x", %{})
    |> put_req_header("authorization", "Bearer " <> user)
    |> InviteLinkController.join(%{"code" => code})
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
