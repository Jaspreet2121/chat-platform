defmodule ConversationService.ConversationClientHttpIntegrationTest do
  @moduledoc """
  Proves the Conversation HTTP client adapter (`SharedInfra.ConversationClientHttp`) round-trips over a
  REAL localhost listener and reconstructs the EXACT in-process shape (incl. atom-keyed conversation/
  participant maps + nested participant lists) + maps transport failure to `{:error,
  :conversation_unavailable}`. Tagged `:http_integration` (real Cowboy listener) — EXCLUDED by default
  so the plain suite stays in-process + Docker-free. Run with `mix test --include http_integration`.
  """
  use ExUnit.Case, async: false

  @port 4192
  @token "test-internal-token"

  setup do
    prev_token = Application.get_env(:shared_infra, :internal_api_token)
    prev_url = Application.get_env(:shared_infra, :conversation_service_url)
    Application.put_env(:shared_infra, :internal_api_token, @token)

    start_supervised!(
      {Plug.Cowboy, scheme: :http, plug: ConversationService.HTTP.Router, options: [port: @port]}
    )

    on_exit(fn ->
      if prev_token,
        do: Application.put_env(:shared_infra, :internal_api_token, prev_token),
        else: Application.delete_env(:shared_infra, :internal_api_token)

      if prev_url,
        do: Application.put_env(:shared_infra, :conversation_service_url, prev_url),
        else: Application.delete_env(:shared_infra, :conversation_service_url)
    end)

    :ok
  end

  @tag :http_integration
  test "get_conversation over HTTP == in-process (atom-keyed/nested participant shapes)" do
    Application.put_env(:shared_infra, :conversation_service_url, "http://localhost:#{@port}")
    attrs = %{"conversation_id" => "conv_1", "user_id" => "user_1"}

    assert SharedInfra.ConversationClientHttp.get_conversation(attrs) ==
             ConversationService.Conversations.get_conversation(attrs)
  end

  @tag :http_integration
  test "add_participant over HTTP == in-process" do
    Application.put_env(:shared_infra, :conversation_service_url, "http://localhost:#{@port}")

    attrs = %{
      "conversation_id" => "conv_1",
      "user_id" => "user_2",
      "actor_user_id" => "user_1",
      "role" => "member"
    }

    assert SharedInfra.ConversationClientHttp.add_participant(attrs) ==
             ConversationService.Participants.add_participant(attrs)
  end

  @tag :http_integration
  test "transport failure (no listener) → {:error, :conversation_unavailable}" do
    Application.put_env(:shared_infra, :conversation_service_url, "http://localhost:4198")

    assert SharedInfra.ConversationClientHttp.get_conversation(%{
             "conversation_id" => "c",
             "user_id" => "u"
           }) ==
             {:error, :conversation_unavailable}
  end
end
