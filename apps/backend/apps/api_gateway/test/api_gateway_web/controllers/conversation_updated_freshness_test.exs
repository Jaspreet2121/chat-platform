defmodule ApiGatewayWeb.ConversationUpdatedFreshnessTest do
  @moduledoc """
  Both HTTP create paths' `conversation_updated` frame must carry the timestamp of the message it was
  triggered by — not the one before it. The socket path's twin lives in
  RealtimeGateway.ConversationUpdatedFreshnessTest; the three diverged before (the first-party path did
  not broadcast message_created at all until b449f28), so each is locked on its own.

  THE DEFECT. `updated_at` on the wire is `conversations.last_message_at`, a denormalised column. Under
  the Scylla store `ScyllaAdapter.put_message/1` only STAGES a Kafka event — `InboxFromTopic` writes the
  column later, and is deliberately its single idempotent writer. The fan-out fires as soon as
  `create_message` returns, re-reads a row the projection has not reached, and ships the PREVIOUS
  message's stamp. Captured on hardware: a send at 11:58:01 produced a frame carrying 06:24:40.305Z.

  `ConvStub.inbox_rows/1` ALWAYS answers @stale_row_at, standing in for that unprojected column. A frame
  carrying it is the bug.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.MessageController
  alias ApiGatewayWeb.V1.MessageController, as: V1MessageController

  @conversation "11111111-1111-4111-8111-111111111111"
  @sender "22222222-2222-4222-8222-222222222222"
  @peer "33333333-3333-4333-8333-333333333333"
  @app "44444444-4444-4444-8444-444444444444"

  # What the unprojected row still holds — the PREVIOUS message.
  @stale_row_at "2026-08-28T06:24:40.305000Z"
  # What the message we are about to send actually committed as.
  @committed_at "2026-08-28T06:28:01.117204Z"
  # …and what the unprojected row still says the preview is.
  @stale_preview "the PREVIOUS message"

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer sender"}),
      do:
        {:ok,
         %{
           user_id: "22222222-2222-4222-8222-222222222222",
           app_id: "44444444-4444-4444-8444-444444444444"
         }}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConvStub do
    @moduledoc false
    def get_conversation_app(_attrs), do: {:ok, %{}}

    def get_conversation(_attrs) do
      {:ok,
       %{
         app_id: "44444444-4444-4444-8444-444444444444",
         participants: [
           %{user_id: "22222222-2222-4222-8222-222222222222"},
           %{user_id: "33333333-3333-4333-8333-333333333333"}
         ]
       }}
    end

    def authorize_send(_attrs), do: {:ok, %{authorized: true}}

    # ALWAYS stale: the Kafka projection has not run. The fix must not depend on this ever advancing.
    def inbox_rows(%{"user_ids" => user_ids}) do
      rows =
        Enum.map(user_ids, fn user_id ->
          %{
            user_id: user_id,
            conversation_id: "11111111-1111-4111-8111-111111111111",
            type: "direct",
            title: nil,
            last_message_preview: "the PREVIOUS message",
            last_message_kind: "text",
            unread_count: 0,
            updated_at: "2026-08-28T06:24:40.305000Z"
          }
        end)

      {:ok, %{rows: rows}}
    end
  end

  defmodule MsgStub do
    @moduledoc false
    # A committed message stamped @committed_at — the post-write truth the frame must reflect. String
    # keys on purpose: this is the shape the client returns over internal HTTP, and the floor has to read
    # created_at out of BOTH key styles.
    def create_message(attrs) do
      {:ok,
       %{
         "message_id" => "m-1",
         "conversation_id" => Map.get(attrs, "conversation_id"),
         "sender_user_id" => Map.get(attrs, "sender_user_id"),
         "message_type" => Map.get(attrs, "message_type"),
         "body" => Map.get(attrs, "body"),
         "metadata" => Map.get(attrs, "metadata") || %{},
         "status" => "active",
         "created_at" => "2026-08-28T06:28:01.117204Z"
       }}
    end
  end

  defmodule MediaStub do
    @moduledoc false
    # /v1 validates an attachment before sending (v1.invalid_media otherwise). The preview rules never
    # read the asset — they read the message's own metadata.content_type — but the PATH does, so the
    # media case needs a valid one to reach the broadcast at all.
    def get_asset(%{"media_id" => media_id}) do
      {:ok,
       %{
         media_id: media_id,
         purpose: "message",
         status: "ready",
         owner_user_id: "22222222-2222-4222-8222-222222222222",
         conversation_id: "11111111-1111-4111-8111-111111111111"
       }}
    end
  end

  setup do
    prev = %{
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      conv: Application.get_env(:shared_infra, :conversation_client_adapter),
      msg: Application.get_env(:shared_infra, :message_client_adapter),
      media: Application.get_env(:shared_infra, :media_client_adapter),
      persist: Application.get_env(:message_service, :message_persistence, false),
      backend: System.get_env("V1_RUNTIME_BACKEND")
    }

    # The first-party create only reaches create_message_from_store (the path that broadcasts) when
    # message persistence is on; otherwise it falls through to the placeholder send.
    Application.put_env(:message_service, :message_persistence, true)

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)
    System.put_env("V1_RUNTIME_BACKEND", "ets")

    on_exit(fn ->
      Application.put_env(:message_service, :message_persistence, prev.persist)
      restore(:auth_client_adapter, prev.auth)
      restore(:conversation_client_adapter, prev.conv)
      restore(:message_client_adapter, prev.msg)
      restore(:media_client_adapter, prev.media)

      if prev.backend,
        do: System.put_env("V1_RUNTIME_BACKEND", prev.backend),
        else: System.delete_env("V1_RUNTIME_BACKEND")
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  # --- the two HTTP entry points ---

  defp send_first_party(body) do
    :post
    |> conn("/api/v1/conversations/#{@conversation}/messages", %{})
    |> put_req_header("authorization", "Bearer sender")
    |> MessageController.create(Map.put(body, "conversation_id", @conversation))
  end

  defp send_v1(body) do
    :post
    |> conn("/v1/conversations/#{@conversation}/messages", %{})
    |> assign(:v1_app_id, @app)
    |> assign(:v1_actor, :end_user)
    |> assign(:v1_user_id, @sender)
    |> V1MessageController.create(Map.put(body, "id", @conversation))
  end

  defp text_body, do: %{"message_type" => "text", "body" => "hello"}

  defp media_body do
    %{
      "message_type" => "media",
      "body" => "photo.png",
      "media_id" => "m-9",
      "metadata" => %{"content_type" => "image/png"}
    }
  end

  defp sealed_body do
    %{
      "message_type" => "sealed",
      "metadata" => %{"envelopes" => [%{"device_id" => "d1", "ciphertext" => "AA=="}]}
    }
  end

  defp await_frame(user_id) do
    receive do
      %Phoenix.Socket.Broadcast{event: "conversation_updated", payload: payload} -> payload
    after
      1500 -> flunk("no conversation_updated frame for #{user_id}")
    end
  end

  # --- HTTP (first-party) create path ---

  test "first-party create: the frame carries the COMMITTED timestamp, not the unprojected row's" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@peer}")

    assert send_first_party(text_body()).status == 201

    payload = await_frame(@peer)
    assert payload["updated_at"] == @committed_at
    refute payload["updated_at"] == @stale_row_at
  end

  test "first-party create: the SENDER's own frame is fresh too" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@sender}")

    send_first_party(text_body())

    assert await_frame(@sender)["updated_at"] == @committed_at
  end

  test "first-party create: SEALED — the metadata differs, the timestamp must not" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@peer}")

    send_first_party(sealed_body())

    assert await_frame(@peer)["updated_at"] == @committed_at
  end

  # --- /v1 create path ---

  test "/v1 create: the frame carries the COMMITTED timestamp, not the unprojected row's" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@peer}")

    assert send_v1(text_body()).status == 201

    payload = await_frame(@peer)
    assert payload["updated_at"] == @committed_at
    refute payload["updated_at"] == @stale_row_at
  end

  test "/v1 create: SEALED — the metadata differs, the timestamp must not" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@peer}")

    send_v1(sealed_body())

    assert await_frame(@peer)["updated_at"] == @committed_at
  end

  # --- the rest of the frame is untouched ---

  test "only updated_at is corrected — the per-user row is otherwise passed through as read" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@peer}")

    send_first_party(text_body())

    payload = await_frame(@peer)
    assert payload["conversation_id"] == @conversation
    assert payload["unread_count"] == 0
    refute Map.has_key?(payload, "user_id")
    # One updated_at key, in the wire's string style — never both shapes at once.
    assert Enum.count(payload, fn {k, _} -> to_string(k) == "updated_at" end) == 1
  end

  # --- preview + kind composed from the triggering message, on BOTH HTTP paths ---

  test "first-party create: PREVIEW and KIND come from the triggering message, not the row" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@peer}")

    send_first_party(text_body())

    payload = await_frame(@peer)
    assert payload["last_message_preview"] == "hello"
    assert payload["last_message_kind"] == "text"
    refute payload["last_message_preview"] == @stale_preview
  end

  test "/v1 create: PREVIEW and KIND come from the triggering message, not the row" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@peer}")

    send_v1(text_body())

    payload = await_frame(@peer)
    assert payload["last_message_preview"] == "hello"
    assert payload["last_message_kind"] == "text"
    refute payload["last_message_preview"] == @stale_preview
  end

  test "MEDIA on both paths: no preview text, kind from the message's own content_type" do
    for send <- [&send_first_party/1, &send_v1/1] do
      Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@peer}")

      conn = send.(media_body())
      assert conn.status == 201, "send failed: #{conn.status} #{inspect(conn.resp_body)}"

      payload = await_frame(@peer)
      assert payload["last_message_preview"] == nil
      assert payload["last_message_kind"] == "image"

      Phoenix.PubSub.unsubscribe(ApiGateway.PubSub, "user:#{@peer}")
    end
  end

  # --- 108: the sealed gate holds on every path ---

  test "SEALED on both paths: NO content on the wire, kind only" do
    for send <- [&send_first_party/1, &send_v1/1] do
      Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@peer}")

      send.(sealed_body())

      payload = await_frame(@peer)
      assert payload["last_message_preview"] == nil
      assert payload["last_message_kind"] == "sealed"
      refute payload["last_message_preview"] == @stale_preview

      Phoenix.PubSub.unsubscribe(ApiGateway.PubSub, "user:#{@peer}")
    end
  end
end
