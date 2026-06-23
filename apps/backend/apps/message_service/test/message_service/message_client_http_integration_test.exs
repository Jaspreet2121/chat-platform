defmodule MessageService.MessageClientHttpIntegrationTest do
  @moduledoc """
  Proves the Message HTTP client adapter (`SharedInfra.MessageClientHttp`) round-trips over a REAL
  localhost listener and reconstructs the EXACT in-process shape (incl. `list_timeline` →
  `Timeline.list_messages`) + maps transport failure to `{:error, :message_unavailable}`. Tagged
  `:http_integration` (real Cowboy listener) — EXCLUDED by default.

  The `metadata` string-key caveat is proven deterministically at the decoder level in
  `SharedInfra.InternalApiSkipAtomizeTest` (the adapter passes `decode: [skip_atomize: ["metadata"]]`);
  the placeholder paths exercised here carry no metadata, so they confirm adapter↔server wiring +
  that the skip option does not disturb metadata-free shapes.
  """
  use ExUnit.Case, async: false

  @port 4194
  @token "test-internal-token"

  setup do
    prev_token = Application.get_env(:shared_infra, :internal_api_token)
    prev_url = Application.get_env(:shared_infra, :message_service_url)
    Application.put_env(:shared_infra, :internal_api_token, @token)

    start_supervised!(
      {Plug.Cowboy, scheme: :http, plug: MessageService.HTTP.Router, options: [port: @port]}
    )

    on_exit(fn ->
      if prev_token,
        do: Application.put_env(:shared_infra, :internal_api_token, prev_token),
        else: Application.delete_env(:shared_infra, :internal_api_token)

      if prev_url,
        do: Application.put_env(:shared_infra, :message_service_url, prev_url),
        else: Application.delete_env(:shared_infra, :message_service_url)
    end)

    :ok
  end

  @tag :http_integration
  test "create_message over HTTP == in-process (atom-keyed message)" do
    Application.put_env(:shared_infra, :message_service_url, "http://localhost:#{@port}")

    attrs = %{
      "conversation_id" => "c1",
      "sender_user_id" => "u1",
      "message_type" => "text",
      "body" => "hi"
    }

    assert SharedInfra.MessageClientHttp.create_message(attrs) ==
             MessageService.Messages.create_message(attrs)
  end

  @tag :http_integration
  test "list_messages + list_timeline over HTTP == in-process (the distinct routes)" do
    Application.put_env(:shared_infra, :message_service_url, "http://localhost:#{@port}")
    attrs = %{"conversation_id" => "c1"}

    assert SharedInfra.MessageClientHttp.list_messages(attrs) ==
             MessageService.Messages.list_messages(attrs)

    assert SharedInfra.MessageClientHttp.list_timeline(attrs) ==
             MessageService.Timeline.list_messages(attrs)
  end

  @tag :http_integration
  test "mark_read over HTTP == in-process" do
    Application.put_env(:shared_infra, :message_service_url, "http://localhost:#{@port}")
    attrs = %{"conversation_id" => "c1", "message_id" => "m1", "user_id" => "u1"}

    assert SharedInfra.MessageClientHttp.mark_read(attrs) ==
             MessageService.Receipts.mark_read(attrs)
  end

  @tag :http_integration
  test "transport failure (no listener) → {:error, :message_unavailable}" do
    Application.put_env(:shared_infra, :message_service_url, "http://localhost:4196")

    assert SharedInfra.MessageClientHttp.create_message(%{"conversation_id" => "c1"}) ==
             {:error, :message_unavailable}
  end
end
