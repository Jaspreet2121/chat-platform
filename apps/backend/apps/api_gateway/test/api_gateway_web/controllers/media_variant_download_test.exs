defmodule ApiGatewayWeb.MediaVariantDownloadTest do
  @moduledoc """
  `GET /media/:id/download?variant=thumb|medium` (124) is the SAME endpoint under the SAME
  authorization: the variant name is read only after `MediaAuthz.authorize_download/3` has passed,
  so a non-member gets the same opaque 404 for a variant as for the original and the media client
  is never asked (MUT-8). A member's `?variant=thumb` reaches the media client as `"variant" =>
  "thumb"`; no `?variant` passes nothing extra (byte-identical request to before); an unknown name
  is a 400.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.MediaController

  @app "44444444-4444-4444-8444-444444444444"
  @member "22222222-2222-4222-8222-222222222222"
  @stranger "99999999-9999-4999-8999-999999999999"
  @msg_media "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer " <> user_id}) when user_id != "",
      do: {:ok, %{user_id: user_id, app_id: "44444444-4444-4444-8444-444444444444"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule MediaStub do
    @moduledoc false
    def get_asset(%{"media_id" => "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}) do
      {:ok,
       %{
         media_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
         purpose: "message",
         owner_user_id: "77777777-7777-4777-8777-777777777777",
         conversation_id: "11111111-1111-4111-8111-111111111111"
       }}
    end

    def get_asset(_), do: {:error, :not_found}

    # Records the exact attrs the controller sends; the URL reflects the variant so the response can
    # be checked end to end.
    def get_download_url(%{"media_id" => media_id} = attrs) do
      send(self(), {:presign, attrs})
      suffix = if attrs["variant"], do: ".#{attrs["variant"]}.jpg", else: ""

      {:ok,
       %{
         media_id: media_id,
         download_url: "https://minio.local/get/#{media_id}#{suffix}",
         expires_at: "2026-09-15T12:15:00Z",
         mime_type: if(attrs["variant"], do: "image/jpeg", else: "image/png")
       }}
    end
  end

  defmodule MessageStub do
    @moduledoc false
    def media_download_allowed(%{"viewer_user_id" => "22222222-2222-4222-8222-222222222222"}),
      do: {:ok, %{allowed: true}}

    def media_download_allowed(_attrs), do: {:ok, %{allowed: false}}
  end

  defmodule ConvStub do
    @moduledoc false
    def get_conversation(%{"user_id" => "22222222-2222-4222-8222-222222222222"}), do: {:ok, %{}}
    def get_conversation(_), do: {:error, :conversation_forbidden}
  end

  setup do
    prev = %{
      persist: Application.get_env(:media_service, :media_persistence, false),
      media: Application.get_env(:shared_infra, :media_client_adapter),
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      msg: Application.get_env(:shared_infra, :message_client_adapter),
      conv: Application.get_env(:shared_infra, :conversation_client_adapter)
    }

    Application.put_env(:media_service, :media_persistence, true)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :message_client_adapter, MessageStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)

    on_exit(fn ->
      Application.put_env(:media_service, :media_persistence, prev.persist)
      restore(:media_client_adapter, prev.media)
      restore(:auth_client_adapter, prev.auth)
      restore(:message_client_adapter, prev.msg)
      restore(:conversation_client_adapter, prev.conv)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  defp download(user_id, extra_params) do
    :get
    |> conn("/api/v1/media/#{@msg_media}/download", %{})
    |> put_req_header("authorization", "Bearer " <> user_id)
    |> MediaController.download(Map.merge(%{"media_id" => @msg_media}, extra_params))
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "a MEMBER's ?variant=thumb reaches the media client as the variant and answers the variant URL" do
    conn = download(@member, %{"variant" => "thumb"})
    assert conn.status == 200
    b = body(conn)
    assert b["download_url"] == "https://minio.local/get/#{@msg_media}.thumb.jpg"
    assert b["mime_type"] == "image/jpeg"
    # KEY-SET of the endpoint response is unchanged by the variant.
    assert Map.keys(b) |> Enum.sort() == ["download_url", "expires_at", "media_id", "mime_type"]

    assert_received {:presign,
                     %{"media_id" => @msg_media, "app_id" => @app, "variant" => "thumb"}}
  end

  test "no ?variant → the request to the media client carries no variant key (as before)" do
    conn = download(@member, %{})
    assert conn.status == 200
    assert body(conn)["download_url"] == "https://minio.local/get/#{@msg_media}"
    assert_received {:presign, attrs}
    refute Map.has_key?(attrs, "variant")
  end

  test "an unknown variant name is a 400 for a caller allowed to download" do
    conn = download(@member, %{"variant" => "huge"})
    assert conn.status == 400
    assert body(conn)["error"]["code"] == "media.invalid_request"
    refute_received {:presign, _}
  end

  test "MUT-8: a NON-MEMBER's ?variant=thumb is the same opaque 404 — the media client is never asked" do
    conn = download(@stranger, %{"variant" => "thumb"})
    assert conn.status == 404
    assert body(conn)["error"]["code"] == "media.not_found"
    refute conn.resp_body =~ "minio.local"
    refute_received {:presign, _}
  end
end
