defmodule MessageService.MessagePreviewTest do
  @moduledoc """
  `metadata.preview` — the client's inline thumb ({inline_b64 ≤ 2048 chars, w/h 1..64}) — survives
  the metadata whitelist on TEXT and MEDIA rows and rides the create ack and the timeline unchanged
  (MUT-1). Invalid or oversize is dropped and logged, never a refusal (MUT-2). A SEALED message
  carrying one — top-level or in metadata — is refused with :preview_not_allowed (MUT-3): a
  plaintext preview beside ciphertext is a leak. Real store (PostgresAdapter).
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

  # A real (tiny) JPEG header as base64 — decodable, ~60 chars.
  defp b64(bytes \\ 40),
    do: Base.encode64(<<0xFF, 0xD8, 0xFF, 0xE0>> <> :crypto.strong_rand_bytes(bytes))

  defp valid_preview, do: %{"inline_b64" => b64(), "w" => 48, "h" => 32}

  defp create(conversation_id, sender, attrs) do
    Messages.create_message(
      Map.merge(%{"conversation_id" => conversation_id, "sender_user_id" => sender}, attrs)
    )
  end

  defp media(preview),
    do: %{"message_type" => "media", "media_id" => @media, "metadata" => %{"preview" => preview}}

  @tag :postgres_integration
  test "MUT-1 guard: a valid preview on a MEDIA message is kept as-is, on the ack and on the timeline" do
    {conversation, sender} = conversation!()
    preview = valid_preview()

    assert {:ok, ack} = create(conversation, sender, media(preview))
    assert ack.metadata["preview"] == preview
    # KEY-SET: the preview joins media_id and the inline download link; nothing else was invented.
    assert Map.keys(ack.metadata) |> Enum.sort() == ["media", "media_id", "preview"]
    assert is_integer(ack.metadata["preview"]["w"])

    {:ok, %{messages: [row]}} =
      Messages.list_messages(%{"conversation_id" => conversation, "viewer_user_id" => sender})

    assert row.metadata["preview"] == preview
  end

  @tag :postgres_integration
  test "a valid preview on a TEXT message is kept; other kinds ignore it" do
    {conversation, sender} = conversation!()
    preview = valid_preview()

    assert {:ok, text} =
             create(conversation, sender, %{
               "message_type" => "text",
               "body" => "look",
               "metadata" => %{"preview" => preview, "foo" => "bar"}
             })

    assert text.metadata == %{"foo" => "bar", "preview" => preview}

    assert {:ok, location} =
             create(conversation, sender, %{
               "message_type" => "location",
               "body" => "x",
               "metadata" => %{"lat" => "1", "lng" => "2", "preview" => preview}
             })

    refute Map.has_key?(location.metadata, "preview")
  end

  @tag :postgres_integration
  test "MUT-2 guard: an OVERSIZE inline_b64 (4 KB) is dropped and logged — the message still lands" do
    {conversation, sender} = conversation!()
    huge = %{"inline_b64" => Base.encode64(:crypto.strong_rand_bytes(3072)), "w" => 48, "h" => 32}
    assert byte_size(huge["inline_b64"]) > 4000

    log =
      capture_log([level: :info], fn ->
        assert {:ok, ack} = create(conversation, sender, media(huge))
        refute Map.has_key?(ack.metadata, "preview")
        assert Map.keys(ack.metadata) |> Enum.sort() == ["media", "media_id"]
      end)

    assert log =~ "metadata preview dropped reason=inline_b64_too_large"
  end

  @tag :postgres_integration
  test "every other invalid shape is dropped with its reason, never refused" do
    {conversation, sender} = conversation!()

    cases = [
      {%{"inline_b64" => b64(), "w" => 0, "h" => 32}, "bad_dimensions"},
      {%{"inline_b64" => b64(), "w" => 65, "h" => 32}, "bad_dimensions"},
      {%{"inline_b64" => b64(), "w" => "48", "h" => 32}, "bad_dimensions"},
      {%{"inline_b64" => "not base64!!", "w" => 48, "h" => 32}, "inline_b64_not_base64"},
      {%{"w" => 48, "h" => 32}, "inline_b64_missing"},
      {"just a string", "not_a_map"}
    ]

    for {preview, reason} <- cases do
      log =
        capture_log([level: :info], fn ->
          assert {:ok, ack} = create(conversation, sender, media(preview))
          refute Map.has_key?(ack.metadata, "preview")
        end)

      assert log =~ "metadata preview dropped reason=#{reason}"
    end
  end

  @tag :postgres_integration
  test "MUT-3 guard: a SEALED message carrying a preview — top-level or in metadata — is refused" do
    {conversation, sender} = conversation!(true)

    envelope = %{
      "v" => 1,
      "alg" => "x25519-xsalsa20-poly1305",
      "sender_device_id" => "dev-1",
      "sig_b64" => "c2ln",
      "recipients" => [%{"device_id" => "dev-2", "envelope_b64" => "ZW52"}]
    }

    base = %{
      "message_type" => "sealed",
      "client_msg_id" => Ecto.UUID.generate(),
      "sealed" => envelope
    }

    assert {:error, :preview_not_allowed} =
             create(conversation, sender, Map.put(base, "preview", valid_preview()))

    assert {:error, :preview_not_allowed} =
             create(
               conversation,
               sender,
               Map.put(base, "metadata", %{"preview" => valid_preview()})
             )

    # The refusal is about the PREVIEW: the same message without one proceeds to the sealed
    # validation (which then judges the envelope on its own terms).
    refute match?({:error, :preview_not_allowed}, create(conversation, sender, base))
  end
end
