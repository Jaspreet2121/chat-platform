defmodule ApiGatewayWeb.ConversationCreateLimitTest do
  @moduledoc """
  POST /api/v1/conversations — the per-user creation limit (128).

  RATE_LIMIT_POLICY.md has carried this number as backlog since the audit, with the abuse vector named
  verbatim: "Unbounded rows; DM-spamming strangers". Creating the conversation is the FIRST half of
  the stranger story message requests address; the requests bucket is the second half, and this is the
  tap. 20/hour per user, fail-OPEN — an abuse guard, not the security control on this endpoint.

  MUT-11 guard: conversation creation unlimited → RED.

  Docker-free: AuthClient and ConversationClient are stubbed, and the real in-memory limiter decides.
  """
  use ExUnit.Case, async: false

  import Plug.Test

  import Plug.Conn, only: [put_req_header: 3, get_resp_header: 2]

  alias ApiGatewayWeb.ConversationController

  defmodule AuthStub do
    @me "11111111-1111-4111-8111-111111111111"
    def current_session(%{"authorization" => "Bearer me"}),
      do: {:ok, %{user_id: @me, app_id: "33333333-3333-4333-8333-333333333333"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConversationStub do
    def create_conversation(_attrs) do
      {:ok,
       %{
         conversation_id: Ecto.UUID.generate(),
         type: "direct",
         participant_user_ids: [],
         created: true
       }}
    end
  end

  setup do
    previous = %{
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      conversation: Application.get_env(:shared_infra, :conversation_client_adapter),
      limiter: Application.get_env(:shared_infra, :rate_limiter_adapter),
      enabled: Application.get_env(:conversation_service, :conversation_persistence, false)
    }

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConversationStub)
    Application.put_env(:conversation_service, :conversation_persistence, true)

    Application.put_env(
      :shared_infra,
      :rate_limiter_adapter,
      SharedInfra.RateLimiter.InMemoryAdapter
    )

    SharedInfra.RateLimiter.InMemoryAdapter.reset()

    on_exit(fn ->
      Application.put_env(:conversation_service, :conversation_persistence, previous.enabled)
      restore(:auth_client_adapter, previous.auth)
      restore(:conversation_client_adapter, previous.conversation)
      restore(:rate_limiter_adapter, previous.limiter)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  defp create(token \\ "me") do
    params = %{
      "type" => "direct",
      "participant_user_ids" => [Ecto.UUID.generate(), Ecto.UUID.generate()]
    }

    :post
    |> conn("/api/v1/conversations", params)
    |> put_req_header("authorization", "Bearer #{token}")
    |> ConversationController.create(params)
  end

  test "MUT-11 guard: 20 conversations an hour land, the 21st is refused" do
    for _ <- 1..20, do: assert(create().status == 201)

    refused = create()
    assert refused.status == 429
    assert refused.resp_body =~ "conversations.rate_limited"
  end

  test "the refusal carries a retry-after so a client backs off" do
    for _ <- 1..20, do: create()
    assert [retry] = get_resp_header(create(), "retry-after")
    assert String.to_integer(retry) > 0
  end

  test "FAIL-OPEN: a limiter outage lets the create through rather than stopping the product" do
    defmodule BrokenLimiter do
      @behaviour SharedInfra.RateLimiter
      @impl true
      def check_rate(_attrs), do: {:error, :rate_limit_unavailable}
    end

    Application.put_env(:shared_infra, :rate_limiter_adapter, BrokenLimiter)
    assert create().status == 201
  end
end
