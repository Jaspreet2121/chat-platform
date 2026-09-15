defmodule MessageService.MediaLinksTest do
  @moduledoc """
  A media message's payload carries its own presigned download link — on the CREATE ACK and on the
  TIMELINE PAGE — minted at read time through ONE batched `SharedInfra.MediaClient.get_download_urls`
  call per page, and pointing at THAT message's object. View-once media, deleted messages and
  sealed messages get no link; a media-service failure leaves the page untouched. Real store
  (PostgresAdapter, `@tag :postgres_integration`), fake media client (a recording double keyed by
  media_id → object_key, so the URL a message receives can be checked against the key it declared).
  """
  use MessageService.DataCase, async: false

  import ExUnit.CaptureLog

  alias MessageService.{Messages, MessageStore}

  @app "00000000-0000-0000-0000-000000000001"
  @sender "11111111-1111-4111-8111-111111111111"
  @peer "22222222-2222-4222-8222-222222222222"

  @media_a "aaaaaaaa-0000-4000-8000-00000000000a"
  @media_b "aaaaaaaa-0000-4000-8000-00000000000b"
  @key_a "media/u/a/photo-a.png"
  @key_b "media/u/b/photo-b.png"

  defmodule MediaFake do
    @moduledoc false
    # Records every batch call (so "ONE call per page" is countable) and answers a URL that embeds the
    # asset's object_key — the only way a message can be checked against the key it declared.
    def get_download_urls(%{"media_ids" => ids, "app_id" => app_id} = attrs) do
      send(self(), {:presign_batch, ids, app_id, attrs["url_expires_seconds"]})

      keys = %{
        "aaaaaaaa-0000-4000-8000-00000000000a" => "media/u/a/photo-a.png",
        "aaaaaaaa-0000-4000-8000-00000000000b" => "media/u/b/photo-b.png"
      }

      expires_at =
        DateTime.utc_now()
        |> DateTime.add(attrs["url_expires_seconds"] || 900, :second)
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      downloads =
        for id <- ids, key = keys[id], is_binary(key) do
          %{
            media_id: id,
            download_url: "https://minio.test/chat-media/#{key}?X-Amz-Expires=900",
            expires_at: expires_at,
            mime_type: "image/png",
            # A has a server-side thumbnail (124); B has none — nil, exactly as the batch answers it.
            thumb_url:
              if(id == "aaaaaaaa-0000-4000-8000-00000000000a",
                do: "https://minio.test/chat-media/#{key}.thumb.jpg?X-Amz-Expires=900"
              )
          }
        end

      {:ok, %{downloads: downloads}}
    end
  end

  defmodule DownFake do
    @moduledoc false
    def get_download_urls(_attrs), do: {:error, :media_unavailable}
  end

  defmodule NoBatchFake do
    @moduledoc false
    # An adapter WITHOUT the (optional) callback — an older media image, or a partial double.
    def get_asset(_attrs), do: {:error, :not_found}
  end

  setup do
    prev = %{
      persistence: Application.get_env(:message_service, :message_persistence, false),
      adapter:
        Application.get_env(
          :message_service,
          :message_store_adapter,
          MessageStore.QueryPlanAdapter
        ),
      media: Application.get_env(:shared_infra, :media_client_adapter)
    }

    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:message_service, :message_store_adapter, MessageStore.PostgresAdapter)
    Application.put_env(:shared_infra, :media_client_adapter, MediaFake)

    on_exit(fn ->
      Application.put_env(:message_service, :message_persistence, prev.persistence)
      Application.put_env(:message_service, :message_store_adapter, prev.adapter)

      if prev.media,
        do: Application.put_env(:shared_infra, :media_client_adapter, prev.media),
        else: Application.delete_env(:shared_infra, :media_client_adapter)
    end)

    for id <- [@sender, @peer] do
      Repo.query!(
        "INSERT INTO users_auth (id, email, password_hash, created_at, updated_at) " <>
          "VALUES ($1::text::uuid, $2, 'x', now(), now()) ON CONFLICT DO NOTHING",
        [id, "#{id}@test.local"]
      )
    end

    {:ok, conversation_id: conversation!()}
  end

  defp conversation!(app_id \\ @app) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, type, created_by, status, app_id, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, 'direct', $2::text::uuid, 'active', $3::text::uuid, now(), now())",
      [id, @sender, app_id]
    )

    for m <- [@sender, @peer] do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
        [id, m]
      )
    end

    id
  end

  defp send!(conversation_id, attrs) do
    {:ok, message} =
      Messages.create_message(
        Map.merge(%{"conversation_id" => conversation_id, "sender_user_id" => @sender}, attrs)
      )

    message
  end

  defp media_attrs(media_id, key),
    do: %{"message_type" => "media", "media_id" => media_id, "object_key" => key}

  defp page(conversation_id) do
    {:ok, %{messages: messages}} =
      Messages.list_messages(%{"conversation_id" => conversation_id, "viewer_user_id" => @peer})

    messages
  end

  @tag :postgres_integration
  test "CREATE ACK: a media message carries metadata.media.{download_url, download_url_expires_at}, 15-minute TTL, its own object",
       %{conversation_id: conversation_id} do
    ack = send!(conversation_id, media_attrs(@media_a, @key_a))

    # MUT-1 guard: the link is present on the ack.
    assert %{"download_url" => url, "download_url_expires_at" => expires_at} =
             ack.metadata["media"]

    # KEY-SET on the new sub-map, and the existing media keys are untouched beside it.
    # KEY-SET: exactly the link pair plus the thumbnail A has (124).
    assert Map.keys(ack.metadata["media"]) |> Enum.sort() ==
             ["download_url", "download_url_expires_at", "thumb_url"]

    assert ack.metadata["media"]["thumb_url"] =~ "#{@key_a}.thumb.jpg"

    assert Map.keys(ack.metadata) |> Enum.sort() == ["media", "media_id", "object_key"]
    # MUT-3 guard: the URL is for the object this message declared.
    assert url =~ @key_a
    # MUT-2 guard: the TTL requested is 15 minutes, and the advertised expiry is bounded by it.
    assert_received {:presign_batch, [@media_a], @app, 900}
    {:ok, dt, 0} = DateTime.from_iso8601(expires_at)
    assert DateTime.diff(dt, DateTime.utc_now(), :second) in 850..900
  end

  @tag :postgres_integration
  test "TIMELINE PAGE: every media row is linked to ITS OWN object through ONE batch call; text rows untouched",
       %{conversation_id: conversation_id} do
    send!(conversation_id, media_attrs(@media_a, @key_a))
    send!(conversation_id, %{"message_type" => "text", "body" => "hello"})
    send!(conversation_id, media_attrs(@media_b, @key_b))
    # Drain the create-time batches so the page's own call is the only one left to count.
    flush_batches()

    messages = page(conversation_id)
    assert length(messages) == 3

    by_media = Map.new(messages, &{&1.media_id, &1})
    # MUT-3: A's row carries A's key, B's row carries B's key — never swapped, never shared.
    assert by_media[@media_a].metadata["media"]["download_url"] =~ @key_a
    assert by_media[@media_b].metadata["media"]["download_url"] =~ @key_b
    refute by_media[@media_a].metadata["media"]["download_url"] =~ @key_b

    # thumb_url only where the batch answered one: A yes, B no key at all.
    assert by_media[@media_a].metadata["media"]["thumb_url"] =~ "#{@key_a}.thumb.jpg"
    refute Map.has_key?(by_media[@media_b].metadata["media"], "thumb_url")

    assert Map.keys(by_media[@media_b].metadata["media"]) |> Enum.sort() ==
             ["download_url", "download_url_expires_at"]

    text = by_media[nil]
    assert text.message_type == "text"
    refute Map.has_key?(text.metadata, "media")

    # ONE presign call for the whole page, carrying both ids.
    assert_received {:presign_batch, ids, @app, 900}
    assert Enum.sort(ids) == [@media_a, @media_b]
    refute_received {:presign_batch, _, _, _}
  end

  @tag :postgres_integration
  test "VIEW-ONCE media is never linked (the endpoint's 120 s deny-on-open rule would be bypassed)",
       %{conversation_id: conversation_id} do
    ack = send!(conversation_id, Map.put(media_attrs(@media_a, @key_a), "view_once", true))
    assert ack.view_once == true
    refute Map.has_key?(ack.metadata, "media")
    refute_received {:presign_batch, _, _, _}

    [row] = page(conversation_id)
    refute Map.has_key?(row.metadata, "media")
    refute_received {:presign_batch, _, _, _}
  end

  @tag :postgres_integration
  test "a DELETED media message is not linked", %{conversation_id: conversation_id} do
    ack = send!(conversation_id, media_attrs(@media_a, @key_a))
    flush_batches()

    {:ok, _} =
      Messages.delete_message(%{
        "conversation_id" => conversation_id,
        "message_id" => ack.message_id,
        "bucket_date" => Map.get(ack, :bucket_date),
        "actor_user_id" => @sender
      })

    [row] = page(conversation_id)
    assert row.deleted_at
    refute Map.has_key?(row.metadata || %{}, "media")
    refute_received {:presign_batch, _, _, _}
  end

  @tag :postgres_integration
  test "FAIL-SOFT: media-service down, or an adapter without the callback → page unchanged, logged once, never failed",
       %{conversation_id: conversation_id} do
    send!(conversation_id, media_attrs(@media_a, @key_a))
    flush_batches()

    Application.put_env(:shared_infra, :media_client_adapter, DownFake)

    log =
      capture_log([level: :warning], fn ->
        assert [row] = page(conversation_id)
        refute Map.has_key?(row.metadata, "media")
      end)

    assert log =~ "media links skipped"
    assert log =~ "media_unavailable"

    Application.put_env(:shared_infra, :media_client_adapter, NoBatchFake)

    log =
      capture_log([level: :warning], fn ->
        assert [row] = page(conversation_id)
        refute Map.has_key?(row.metadata, "media")
      end)

    assert log =~ "media links skipped"
  end

  defp flush_batches do
    receive do
      {:presign_batch, _, _, _} -> flush_batches()
    after
      0 -> :ok
    end
  end
end
