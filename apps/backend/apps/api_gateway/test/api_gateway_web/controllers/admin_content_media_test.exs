defmodule ApiGatewayWeb.AdminContentMediaTest.MediaStub do
  @moduledoc false
  @behaviour SharedInfra.MediaClient

  @impl true
  def create_upload(_attrs), do: {:error, :not_used}
  @impl true
  def complete_upload(_attrs), do: {:error, :not_used}
  @impl true
  def get_asset(_attrs), do: {:error, :not_used}

  # Shape: (media_id, app_id, purpose). object_key is resolved server-side from the row, so the URL is
  # derived from media_id here. Since 113 the purpose is a LIST — moderation must be able to presign a
  # server-generated "user_asset" (a QR sent with /qr) as well as a plain "message", and matching the
  # list here is what pins that the assertion was widened rather than dropped.
  @impl true
  def get_download_url(%{
        "media_id" => media_id,
        "app_id" => _app,
        "purpose" => ["message", "user_asset"]
      }) do
    {:ok, %{download_url: "https://media.growblic.com/get/#{media_id}?X-Amz-Signature=stub"}}
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
  def get_asset(_attrs), do: {:error, :media_unavailable}
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

  # The asset's app_id is the conversation's tenant, resolved by the caller and threaded into enrich_media.
  @app "44444444-4444-4444-8444-444444444444"

  describe "enrich_media/2 (content.read / root)" do
    test "attaches a presigned download_url to media messages (signed by media_id + app_id)" do
      enriched = Controller.enrich_media(@image_message, @app)

      assert enriched.download_url =~ "https://media.growblic.com/get/media-1"
      # the rest of the message is untouched (metadata, caption etc. remain for the viewer)
      assert enriched.media_id == "media-1"
      assert enriched.metadata["content_type"] == "image/png"
      assert enriched.caption == "look at this"
    end

    test "voice messages get a download_url too" do
      assert Controller.enrich_media(@voice_message, @app).download_url =~ "media-2"
    end

    test "text messages pass through untouched" do
      assert Controller.enrich_media(@text_message, @app) == @text_message
    end

    test "media message without a media_id passes through without a URL" do
      # object_key is no longer consulted — the gate is media_id + app_id (the row is the source of truth).
      message = %{@image_message | media_id: nil}
      assert Controller.enrich_media(message, @app) == message
    end

    test "presign failure degrades gracefully (message kept, no URL)" do
      Application.put_env(:shared_infra, :media_client_adapter, __MODULE__.FailingMediaStub)
      assert Controller.enrich_media(@image_message, @app) == @image_message
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
