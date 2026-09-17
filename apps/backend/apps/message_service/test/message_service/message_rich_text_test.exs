defmodule MessageService.MessageRichTextTest do
  @moduledoc """
  `font` + `entities` through the REAL create path and back off the timeline: kept verbatim on a
  text body and a media caption, dropped-not-refused when invalid, and stripped SILENTLY (no error)
  from a sealed message, whose metadata is the envelope and nothing else.
  """
  use MessageService.DataCase, async: false

  import ExUnit.CaptureLog

  alias MessageService.Messages

  @tenant "00000000-0000-0000-0000-000000000001"
  @media "aaaaaaaa-0000-4000-8000-00000000000a"

  setup do
    prev = Application.get_env(:message_service, :message_persistence, false)

    prev_adapter =
      Application.get_env(
        :message_service,
        :message_store_adapter,
        MessageService.MessageStore.QueryPlanAdapter
      )

    Application.put_env(:message_service, :message_persistence, true)

    Application.put_env(
      :message_service,
      :message_store_adapter,
      MessageService.MessageStore.PostgresAdapter
    )

    on_exit(fn ->
      Application.put_env(:message_service, :message_persistence, prev)
      Application.put_env(:message_service, :message_store_adapter, prev_adapter)
    end)

    :ok
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active', now(), now())",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp conversation!(secret \\ false) do
    id = Ecto.UUID.generate()
    sender = user!()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, secret, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'direct', $3::text::uuid, $4, now(), now())",
      [id, @tenant, sender, secret]
    )

    Repo.query!(
      "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
      [id, sender]
    )

    {id, sender}
  end

  defp create(conversation_id, sender, attrs) do
    Messages.create_message(
      Map.merge(%{"conversation_id" => conversation_id, "sender_user_id" => sender}, attrs)
    )
  end

  defp timeline(conversation_id, viewer) do
    {:ok, %{messages: messages}} =
      Messages.list_messages(%{"conversation_id" => conversation_id, "viewer_user_id" => viewer})

    messages
  end

  @bold %{"type" => "bold", "offset" => 0, "length" => 5}
  @link %{"type" => "link", "offset" => 6, "length" => 5, "url" => "https://example.com"}

  @tag :postgres_integration
  test "MUT-1/MUT-5 guard: a TEXT message keeps its font and entities verbatim, on the ack and the timeline" do
    {conversation, sender} = conversation!()

    assert {:ok, ack} =
             create(conversation, sender, %{
               "message_type" => "text",
               "body" => "hello world",
               "metadata" => %{"font" => "handwritten", "entities" => [@bold, @link]}
             })

    assert ack.metadata["font"] == "handwritten"
    assert ack.metadata["entities"] == [@bold, @link]
    assert Map.keys(ack.metadata) |> Enum.sort() == ["entities", "font"]

    [row] = timeline(conversation, sender)
    assert row.metadata["font"] == "handwritten"
    assert row.metadata["entities"] == [@bold, @link]
  end

  @tag :postgres_integration
  test "a MEDIA message carries them too, with the spans measured against the CAPTION" do
    {conversation, sender} = conversation!()

    assert {:ok, ack} =
             create(conversation, sender, %{
               "message_type" => "media",
               "media_id" => @media,
               "caption" => "hello world",
               "metadata" => %{"font" => "serif", "entities" => [@bold]}
             })

    assert ack.metadata["font"] == "serif"
    assert ack.metadata["entities"] == [@bold]
    assert ack.metadata["caption"] == "hello world"

    # A span that fits the BODY of some other message but not this caption is dropped.
    log =
      capture_log([level: :info], fn ->
        assert {:ok, short} =
                 create(conversation, sender, %{
                   "message_type" => "media",
                   "media_id" => @media,
                   "caption" => "hi",
                   "metadata" => %{"entities" => [@bold]}
                 })

        refute Map.has_key?(short.metadata, "entities")
      end)

    assert log =~ "metadata entities dropped n=1 reason=out_of_range"
  end

  @tag :postgres_integration
  test "an UNKNOWN font and INVALID entities are dropped — the message still lands" do
    {conversation, sender} = conversation!()

    log =
      capture_log([level: :info], fn ->
        assert {:ok, ack} =
                 create(conversation, sender, %{
                   "message_type" => "text",
                   "body" => "hello world",
                   "metadata" => %{
                     "font" => "wingdings",
                     "entities" => [@bold, %{"type" => "rainbow", "offset" => 0, "length" => 1}]
                   }
                 })

        refute Map.has_key?(ack.metadata, "font")
        assert ack.metadata["entities"] == [@bold]
      end)

    assert log =~ "metadata font dropped reason=unknown_font"
    assert log =~ "metadata entities dropped n=1 reason=unknown_type"
  end

  @tag :postgres_integration
  test "UTF-16 bounds hold through the real path: an emoji body admits the shifted span" do
    {conversation, sender} = conversation!()
    body = "😀secret"

    assert {:ok, ack} =
             create(conversation, sender, %{
               "message_type" => "text",
               "body" => body,
               "metadata" => %{
                 "entities" => [%{"type" => "spoiler", "offset" => 2, "length" => 6}]
               }
             })

    assert ack.metadata["entities"] == [%{"type" => "spoiler", "offset" => 2, "length" => 6}]
  end

  @tag :postgres_integration
  test "a SEALED message's font/entities are stripped SILENTLY — no error, and no plaintext hint stored" do
    {conversation, sender} = conversation!(true)

    envelope = %{
      "v" => 1,
      "alg" => "xsalsa20poly1305-sealedbox+ed25519",
      "sender_device_id" => "dev-1",
      "sig_b64" => "c2ln",
      "recipients" => [%{"device_id" => "dev-2", "envelope_b64" => "ZW52"}]
    }

    attrs = %{
      "message_type" => "sealed",
      "client_msg_id" => Ecto.UUID.generate(),
      "sealed" => envelope,
      # Both shapes at once: top-level AND inside metadata.
      "font" => "elegant",
      "entities" => [@bold],
      "metadata" => %{"font" => "serif", "entities" => [@link]}
    }

    result = create(conversation, sender, attrs)

    # Whatever the envelope validation decides, it is never a REFUSAL over the formatting …
    refute match?({:error, :preview_not_allowed}, result)

    case result do
      {:ok, ack} ->
        # … and nothing formatting-shaped survives into the stored metadata.
        assert Map.keys(ack.metadata) == ["sealed"]
        refute Map.has_key?(ack.metadata, "font")
        refute Map.has_key?(ack.metadata, "entities")

      {:error, reason} ->
        # The sealed envelope itself was judged; the formatting played no part.
        assert reason == :secret_sealed_invalid
    end
  end
end
