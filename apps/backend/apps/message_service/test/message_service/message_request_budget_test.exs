defmodule MessageService.MessageRequestBudgetTest do
  @moduledoc """
  MESSAGE REQUESTS (128) — the per-pair send budget, driven through the REAL create path.

  It lives in message-service, not in the gateway controller, and that placement is the point: the
  first-party REST path, the socket path and the `/v1` partner path all funnel through
  `Messages.create_message/1`, while only the first two ever run `authorize_send`. A gate in the
  gateway would have left `/v1` open to anyone holding an API key.

  The mutation guards these carry:

    * MUT-4 the 4th message to an unaccepted request is accepted → RED
    * MUT-5 an accepted conversation pays a stranger check per message → RED
    * MUT-9 a /v1 send bypasses the request gate → RED (this suite calls the same seam /v1 calls)

  The limiter is stubbed with a counting adapter rather than a fake Redis, because what is under test
  is WHICH KEY is charged and WHEN — not RESP framing, which `SharedInfra.RedisKVPoolTest` owns.
  """
  use MessageService.DataCase, async: false

  alias MessageService.Messages

  # Statements per send on the create path today. See the assertion in the MUT-5 guard for why this is
  # pinned to an absolute number rather than compared against a control.
  @queries_per_send 12

  defmodule CountingLimiter do
    @moduledoc false
    @behaviour SharedInfra.RateLimiter

    def start do
      {:ok, pid} = Agent.start_link(fn -> %{} end)
      Process.put(__MODULE__, pid)
      pid
    end

    def counts(pid), do: Agent.get(pid, & &1)

    @impl true
    def check_rate(%{"key" => key, "limit" => limit}) do
      pid = Application.get_env(:message_service, :test_limiter_agent)

      n =
        Agent.get_and_update(pid, fn s ->
          {Map.get(s, key, 0) + 1, Map.update(s, key, 1, &(&1 + 1))}
        end)

      if n <= limit, do: :ok, else: {:error, :rate_limited, 60}
    end
  end

  setup do
    prev = Application.get_env(:message_service, :message_persistence, false)

    prev_adapter =
      Application.get_env(
        :message_service,
        :message_store_adapter,
        MessageService.MessageStore.QueryPlanAdapter
      )

    prev_limiter = Application.get_env(:shared_infra, :rate_limiter_adapter)

    {:ok, agent} = Agent.start(fn -> %{} end)

    Application.put_env(:message_service, :message_persistence, true)

    Application.put_env(
      :message_service,
      :message_store_adapter,
      MessageService.MessageStore.PostgresAdapter
    )

    Application.put_env(:shared_infra, :rate_limiter_adapter, CountingLimiter)
    Application.put_env(:message_service, :test_limiter_agent, agent)

    on_exit(fn ->
      Application.put_env(:message_service, :message_persistence, prev)
      Application.put_env(:message_service, :message_store_adapter, prev_adapter)

      if prev_limiter,
        do: Application.put_env(:shared_infra, :rate_limiter_adapter, prev_limiter),
        else: Application.delete_env(:shared_infra, :rate_limiter_adapter)
    end)

    {:ok, agent: agent}
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, phone_number, status) VALUES ($1::text::uuid, $2, 'active')",
      [id, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  # A direct conversation with a canonical direct_key and BOTH participant rows, the recipient's
  # stamped pending when `pending?` — the exact state the creation path leaves behind.
  defp direct!(sender, recipient, pending?) do
    id = Ecto.UUID.generate()
    direct_key = [sender, recipient] |> Enum.sort() |> Enum.join(":")

    Repo.query!(
      "INSERT INTO conversations (id, type, created_by, direct_key) " <>
        "VALUES ($1::text::uuid, 'direct', $2::text::uuid, $3)",
      [id, sender, direct_key]
    )

    for u <- [sender, recipient] do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
        [id, u]
      )
    end

    if pending? do
      Repo.query!(
        "UPDATE conversation_participants SET request_pending_at = now() " <>
          "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
        [id, recipient]
      )
    end

    {id, direct_key}
  end

  defp send!(conversation_id, sender) do
    Messages.create_message(%{
      "conversation_id" => conversation_id,
      "sender_user_id" => sender,
      "message_type" => "text",
      "body" => "hello #{System.unique_integer([:positive])}"
    })
  end

  @tag :postgres_integration
  test "MUT-4 guard: three messages land, the fourth is refused with a named error",
       %{agent: agent} do
    sender = user!()
    recipient = user!()
    {conversation, direct_key} = direct!(sender, recipient, true)

    for _ <- 1..3, do: assert({:ok, _} = send!(conversation, sender))
    assert {:error, :message_request_limit} = send!(conversation, sender)

    # Charged on the PAIR, using the canonical direct_key that already exists on the row.
    assert Map.has_key?(CountingLimiter.counts(agent), "message_request:" <> direct_key)
  end

  @tag :postgres_integration
  test "an ACCEPTED conversation is not budgeted at all — no limiter key is ever charged",
       %{agent: agent} do
    sender = user!()
    recipient = user!()
    {conversation, direct_key} = direct!(sender, recipient, false)

    for _ <- 1..10, do: assert({:ok, _} = send!(conversation, sender))

    refute Map.has_key?(CountingLimiter.counts(agent), "message_request:" <> direct_key)
  end

  @tag :postgres_integration
  test "the RECIPIENT replying before accepting spends nothing — the budget is the stranger's",
       %{agent: agent} do
    sender = user!()
    recipient = user!()
    {conversation, direct_key} = direct!(sender, recipient, true)

    for _ <- 1..5, do: assert({:ok, _} = send!(conversation, recipient))

    refute Map.has_key?(CountingLimiter.counts(agent), "message_request:" <> direct_key)
    # And the stranger's own budget is untouched by those replies.
    for _ <- 1..3, do: assert({:ok, _} = send!(conversation, sender))
    assert {:error, :message_request_limit} = send!(conversation, sender)
  end

  @tag :postgres_integration
  test "MUT-5 guard: 20 sends to an ACCEPTED conversation cost no more queries than 20 sends to a conversation that never had a request" do
    sender = user!()
    {never_requested, _} = direct!(sender, user!(), false)

    accepted_recipient = user!()
    {accepted, _} = direct!(sender, accepted_recipient, true)

    Repo.query!(
      "UPDATE conversation_participants SET request_pending_at = NULL " <>
        "WHERE conversation_id = $1::text::uuid",
      [accepted]
    )

    baseline = count_queries(fn -> for _ <- 1..20, do: send!(never_requested, sender) end)
    after_accept = count_queries(fn -> for _ <- 1..20, do: send!(accepted, sender) end)

    # BOTH assertions are needed, and the second is the one that catches the real mutation. A stranger
    # check added UNCONDITIONALLY costs both conversations equally and slips past a relative compare;
    # only an absolute count sees it. 12 statements per send is what this path costs today, and the
    # feature is required to leave that untouched — pinning it is deliberate, because a send path that
    # silently grows a query is exactly what this guard exists to notice.
    assert after_accept == baseline,
           "an accepted conversation cost #{after_accept} queries for 20 sends against a baseline " <>
             "of #{baseline} — the request state is being read per message for accepted chats only"

    assert after_accept == 20 * @queries_per_send,
           "20 sends cost #{after_accept} queries, expected #{20 * @queries_per_send} " <>
             "(#{@queries_per_send} per send). The request state must ride the conversation row the " <>
             "create path already fetches (MessageService.ConversationRow), not a read of its own. " <>
             "If a send legitimately gained a statement, change the constant and say why."
  end

  defp count_queries(fun) do
    handler = "request-budget-query-count-#{System.unique_integer([:positive])}"
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    :telemetry.attach(
      handler,
      [:message_service, :repo, :query],
      fn _event, _measure, _meta, _config -> Agent.update(counter, &(&1 + 1)) end,
      nil
    )

    fun.()
    :telemetry.detach(handler)
    Agent.get(counter, & &1)
  end
end
