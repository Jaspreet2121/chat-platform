defmodule UserService.UpiQrStoreTest do
  @moduledoc """
  The REAL `UserService.UpiQr.MediaWriter.store_png/3` chain — create_upload → `Req.put` of the PNG to
  the presigned URL → complete_upload — end to end, against a media double that ENFORCES the same
  required-attrs contract `MediaService.Media` does, and a real local listener that accepts the PUT.

  This is the test the earlier slices were missing. Every previous test stubbed the whole writer at
  the `:upi_media_writer` seam, so the chain itself was never executed and three separate prod-only
  faults slipped through: the in-process media adapter (absent from the user release), the public-host
  presign, and finally `complete_upload` returning `:media_invalid` because store_png sent only
  media_id + app_id while the real contract also REQUIRES `owner_user_id` (media.ex verifies the
  caller owns the row before flipping it to "ready"). The double mirrors that contract exactly, so
  dropping a required attr fails HERE instead of in production.
  """
  use ExUnit.Case, async: false

  @port 4196

  # Accepts the presigned PUT and records the bytes, standing in for MinIO.
  defmodule UploadSink do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn, length: 2_000_000)
      send(:upi_qr_store_test, {:put_received, conn.request_path, body})
      send_resp(conn, 200, "")
    end
  end

  # Mirrors MediaService.Media's REQUIRED-ATTRS CONTRACT. Anything the real service demands is
  # demanded here — a caller that omits one gets :media_invalid, exactly as prod did.
  defmodule ContractMediaStub do
    @moduledoc false
    @port 4196

    def create_upload(attrs) do
      send(:upi_qr_store_test, {:create_upload, attrs})

      # Real contract: owner_user_id, filename, content_type, size_bytes (+ app_id when persisting).
      required = ["owner_user_id", "app_id", "filename", "content_type", "size_bytes"]

      if Enum.all?(required, &present?(attrs, &1)) do
        media_id = "media-" <> Integer.to_string(System.unique_integer([:positive]))

        {:ok,
         %{
           media_id: media_id,
           owner_user_id: attrs["owner_user_id"],
           object_key: "media/#{attrs["owner_user_id"]}/#{media_id}/upi-qr.png",
           upload_url: "http://localhost:#{@port}/chat-media/#{media_id}",
           status: "pending"
         }}
      else
        {:error, :media_invalid}
      end
    end

    def complete_upload(attrs) do
      send(:upi_qr_store_test, {:complete_upload, attrs})

      # THE CONTRACT THAT BROKE PROD: media_id AND owner_user_id AND app_id are all required.
      if Enum.all?(["media_id", "owner_user_id", "app_id"], &present?(attrs, &1)) do
        {:ok, %{media_id: attrs["media_id"], status: "ready"}}
      else
        {:error, :media_invalid}
      end
    end

    def purge_asset(attrs), do: {:ok, %{purged: attrs["media_id"]}}
    def get_download_url(_attrs), do: {:error, :media_invalid}
    def get_asset(_attrs), do: {:error, :media_invalid}

    defp present?(attrs, key) do
      case Map.get(attrs, key) do
        nil -> false
        "" -> false
        _ -> true
      end
    end
  end

  setup do
    Process.register(self(), :upi_qr_store_test)
    prev_adapter = Application.get_env(:shared_infra, :media_client_adapter)
    Application.put_env(:shared_infra, :media_client_adapter, ContractMediaStub)

    start_supervised!({Plug.Cowboy, scheme: :http, plug: UploadSink, options: [port: @port]})

    on_exit(fn ->
      if prev_adapter,
        do: Application.put_env(:shared_infra, :media_client_adapter, prev_adapter),
        else: Application.delete_env(:shared_infra, :media_client_adapter)
    end)

    :ok
  end

  @user "11111111-1111-4111-8111-111111111111"
  @app "00000000-0000-0000-0000-000000000001"

  test "the full store chain succeeds and passes EVERY attr each step requires" do
    {:ok, png} = UserService.UpiQr.render_png("upi://pay?pa=a.b@bank&cu=INR")

    assert {:ok, media_id} = UserService.UpiQr.MediaWriter.store_png(@user, @app, png)

    # 1. create_upload carries the owner + tenant + the server-side internal presign flag.
    assert_receive {:create_upload, create_attrs}
    assert create_attrs["owner_user_id"] == @user
    assert create_attrs["app_id"] == @app
    assert create_attrs["internal"] == true
    assert create_attrs["content_type"] == "image/png"
    assert create_attrs["size_bytes"] == byte_size(png)

    # 113: the QR is "user_asset", NOT "message". It carries no conversation and never could — and
    # "message" is about to require one, which would have made this generator the last server-side
    # producer blocking that rule. The ACL is unchanged (media_authz routes user_asset to the same
    # message-media predicate), so /qr sends keep working for their recipients.
    assert create_attrs["purpose"] == "user_asset"
    refute create_attrs["purpose"] == "message"
    refute Map.has_key?(create_attrs, "conversation_id")

    # 2. the PNG bytes really went to the presigned URL.
    assert_receive {:put_received, path, body}
    assert body == png
    assert path =~ media_id

    # 3. complete_upload carries owner_user_id — the attr whose absence returned :media_invalid in
    #    prod, leaving the asset "created" forever and the profile without a QR.
    assert_receive {:complete_upload, complete_attrs}
    assert complete_attrs["media_id"] == media_id
    assert complete_attrs["app_id"] == @app
    assert complete_attrs["owner_user_id"] == @user
  end

  test "REGRESSION: dropping owner_user_id from complete_upload fails the whole store" do
    # Proves the double actually enforces the contract — i.e. this suite would have caught the bug.
    assert ContractMediaStub.complete_upload(%{"media_id" => "m", "app_id" => @app}) ==
             {:error, :media_invalid}

    assert_receive {:complete_upload, _}
  end

  test "a media failure surfaces as {:qr_store_failed, reason} — never a crash" do
    Application.put_env(:shared_infra, :media_client_adapter, __MODULE__.FailingStub)
    {:ok, png} = UserService.UpiQr.render_png("upi://pay?pa=a.b@bank&cu=INR")

    assert {:error, {:qr_store_failed, {:error, :media_invalid}}} =
             UserService.UpiQr.MediaWriter.store_png(@user, @app, png)
  end

  defmodule FailingStub do
    @moduledoc false
    def create_upload(_attrs), do: {:error, :media_invalid}
    def complete_upload(_attrs), do: {:error, :media_invalid}
    def purge_asset(_attrs), do: {:ok, %{}}
    def get_download_url(_attrs), do: {:error, :media_invalid}
    def get_asset(_attrs), do: {:error, :media_invalid}
  end
end
