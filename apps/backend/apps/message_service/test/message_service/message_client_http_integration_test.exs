defmodule MessageService.MessageClientHttpIntegrationTest do
  @moduledoc """
  Proves the Message HTTP client adapter (`SharedInfra.MessageClientHttp`) round-trips over a REAL
  localhost listener and reconstructs the EXACT in-process shape (incl. `list_timeline` →
  `Timeline.list_messages`) + maps transport failure to `{:error, :message_unavailable}`. Tagged
  `:http_integration` (real Cowboy listener) — EXCLUDED by default.

  The `metadata` string-key caveat is proven deterministically at the decoder level in
  `SharedInfra.InternalApiSkipAtomizeTest` (the adapter passes `decode: [skip_atomize: ["metadata"]]`).
  Most paths exercised here run against the placeholder store and carry no metadata, so they confirm
  adapter↔server wiring + that the skip option does not disturb metadata-free shapes. The `get_message`
  test is the exception: it pins `InMemoryAdapter` so a real row — metadata included — crosses the wire.
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

  # BOTH ADAPTERS, ONE SET OF ASSERTIONS. The other tests here compare the HTTP adapter against the
  # DOMAIN MODULE; this one compares it against the IN-PROCESS ADAPTER, because the defect this guards
  # is a divergence between the two implementations of the same callback, and only one of them is
  # exercised in dev. Both the found and not-found shapes are compared: an adapter that returns a
  # struct in-process and a map over the wire passes a not-found-only test.
  @tag :http_integration
  test "get_message: HTTP adapter == in-process adapter, found AND not-found" do
    Application.put_env(:shared_infra, :message_service_url, "http://localhost:#{@port}")

    # The default test store is `QueryPlanAdapter`, which answers EVERY get_message with
    # {:error, :message_store_unavailable}. Comparing two identical error tuples would pass even if
    # one adapter returned a struct and the other a map, so pin a store that actually holds a row.
    prev_store = Application.get_env(:message_service, :message_store_adapter)

    Application.put_env(
      :message_service,
      :message_store_adapter,
      MessageService.MessageStore.InMemoryAdapter
    )

    MessageService.MessageStore.InMemoryAdapter.reset()

    on_exit(fn ->
      if prev_store,
        do: Application.put_env(:message_service, :message_store_adapter, prev_store),
        else: Application.delete_env(:message_service, :message_store_adapter)
    end)

    message_id = Ecto.UUID.generate()

    # InMemoryAdapter requires an explicit "bucket_date" that its Scylla/Postgres siblings derive
    # themselves (the caveat `InboxFromTopicTest` also records). Both adapters receive the SAME attrs,
    # so it does not affect what this test compares — the response shape on either side of the wire.
    bucket_date = "2026-08-08"

    # `metadata` is included deliberately: it is the one field the HTTP adapter decodes with
    # `skip_atomize`, so it is where a string-key/atom-key divergence would actually show up.
    {:ok, _} =
      MessageService.MessageStore.InMemoryAdapter.put_message(%{
        "conversation_id" => "c1",
        "bucket_date" => bucket_date,
        "message_id" => message_id,
        "sender_user_id" => "u1",
        "message_type" => "text",
        "body" => "preview me",
        "metadata" => %{"content_type" => "image/jpeg"}
      })

    found = %{"conversation_id" => "c1", "bucket_date" => bucket_date, "message_id" => message_id}
    in_process_found = MessageService.MessageClientInProcess.get_message(found)

    # Assert it really FOUND something before comparing — an {:error, :message_not_found} on both
    # sides would make the equality below vacuous.
    assert {:ok, %{body: "preview me", metadata: %{"content_type" => "image/jpeg"}}} =
             in_process_found

    assert SharedInfra.MessageClientHttp.get_message(found) == in_process_found

    missing = %{
      "conversation_id" => "c1",
      "bucket_date" => bucket_date,
      "message_id" => Ecto.UUID.generate()
    }

    in_process_missing = MessageService.MessageClientInProcess.get_message(missing)
    assert {:error, :message_not_found} = in_process_missing
    assert SharedInfra.MessageClientHttp.get_message(missing) == in_process_missing
  end

  @tag :http_integration
  test "transport failure (no listener) → {:error, :message_unavailable}" do
    Application.put_env(:shared_infra, :message_service_url, "http://localhost:4196")

    assert SharedInfra.MessageClientHttp.create_message(%{"conversation_id" => "c1"}) ==
             {:error, :message_unavailable}
  end
end
