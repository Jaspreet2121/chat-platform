defmodule ApiGatewayWeb.AdminContentMediaTest.MediaStub do
  @moduledoc false
  @behaviour SharedInfra.MediaClient

  @impl true
  def create_upload(_attrs), do: {:error, :not_used}
  @impl true
  def complete_upload(_attrs), do: {:error, :not_used}

  @impl true
  def get_download_url(%{"object_key" => object_key}) do
    {:ok, %{download_url: "https://media.growblic.com/chat-media/#{object_key}?X-Amz-Signature=stub"}}
  end
end

defmodule ApiGatewayWeb.AdminContentMediaTest.FailingMediaStub do
  @moduledoc false
  @behaviour SharedInfra.MediaClient

  @impl true
  def create_upload(_attrs), do: {:error, :media_unavailable}
  @impl true
  def complete_upload(_attrs), do: {:error, :media_unavailable}
  @impl true
  def get_download_url(_attrs), do: {:error, :media_unavailable}
end

defmodule ApiGatewayWeb.AdminContentMediaTest do
  use ExUnit.Case, async: false

  alias ApiGatewayWeb.AdminContentController, as: Controller

  @image_message %{
    message_id: "m1",
    sender_user_id: "u1",
    message_type: "media",
    media_id: "media-1",
    body: nil,
    caption: "look at this",
    status: "active",
    created_at: "2026-07-03T10:00:00Z",
    metadata: %{
      "object_key" => "media/u1/media-1/photo.png",
      "content_type" => "image/png",
      "filename" => "photo.png"
    }
  }

  @voice_message %{
    message_id: "m2",
    sender_user_id: "u2",
    message_type: "media",
    media_id: "media-2",
    body: nil,
    status: "active",
    metadata: %{
      "object_key" => "media/u2/media-2/voice.webm",
      "content_type" => "audio/webm",
      "filename" => "voice.webm"
    }
  }

  @text_message %{
    message_id: "m3",
    sender_user_id: "u1",
    message_type: "text",
    body: "secret text",
    status: "active",
    metadata: %{}
  }

  setup do
    previous = Application.get_env(:shared_infra, :media_client_adapter)
    Application.put_env(:shared_infra, :media_client_adapter, __MODULE__.MediaStub)

    on_exit(fn ->
      if previous do
        Application.put_env(:shared_infra, :media_client_adapter, previous)
      else
        Application.delete_env(:shared_infra, :media_client_adapter)
      end
    end)

    :ok
  end

  describe "enrich_media/1 (content.read / root)" do
    test "attaches a presigned download_url to media messages" do
      enriched = Controller.enrich_media(@image_message)

      assert enriched.download_url =~ "https://media.growblic.com/chat-media/media/u1/media-1/photo.png"
      # the rest of the message is untouched (metadata, caption etc. remain for the viewer)
      assert enriched.media_id == "media-1"
      assert enriched.metadata["content_type"] == "image/png"
      assert enriched.caption == "look at this"
    end

    test "voice messages get a download_url too" do
      assert Controller.enrich_media(@voice_message).download_url =~ "voice.webm"
    end

    test "text messages pass through untouched" do
      assert Controller.enrich_media(@text_message) == @text_message
    end

    test "media message without object_key passes through without a URL" do
      message = %{@image_message | metadata: %{}}
      assert Controller.enrich_media(message) == message
    end

    test "presign failure degrades gracefully (message kept, no URL)" do
      Application.put_env(:shared_infra, :media_client_adapter, __MODULE__.FailingMediaStub)
      assert Controller.enrich_media(@image_message) == @image_message
    end
  end

  describe "mask/1 (no content.read)" do
    test "image message masks to [image hidden] with NO url, media_id, object_key or metadata" do
      masked = Controller.mask(@image_message)

      assert masked.content == "[image hidden]"
      assert masked.message_type == "media"

      # structural no-leak guarantee: whitelist output only
      assert Map.keys(masked) |> Enum.sort() ==
               Enum.sort([
                 :message_id,
                 :sender_user_id,
                 :message_type,
                 :status,
                 :created_at,
                 :edited_at,
                 :deleted_at,
                 :content_length,
                 :content
               ])

      serialized = Jason.encode!(masked)
      refute serialized =~ "media-1"
      refute serialized =~ "object_key"
      refute serialized =~ "photo.png"
      refute serialized =~ "download_url"
      refute serialized =~ "growblic"
    end

    test "voice message masks to [voice message hidden]" do
      assert Controller.mask(@voice_message).content == "[voice message hidden]"
    end

    test "media without content_type masks to generic [media hidden]" do
      message = %{@image_message | metadata: %{"object_key" => "k"}}
      assert Controller.mask(message).content == "[media hidden]"
    end

    test "text message still masks to [content hidden] with length (regression)" do
      masked = Controller.mask(@text_message)
      assert masked.content == "[content hidden]"
      assert masked.content_length == byte_size("secret text")
      refute Jason.encode!(masked) =~ "secret text"
    end
  end
end
