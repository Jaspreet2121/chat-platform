defmodule ApiGatewayWeb.MediaDownloadAuthzTest do
  @moduledoc """
  The download read path never trusts the client. `object_key` is resolved server-side from the row; the
  gateway authorizes by PURPOSE before any URL is minted:
    * message      → OWNER-ANCHORED: member of any conversation with a message referencing the media
                     SENT BY the asset's owner (MessageClient.media_download_allowed); the owner
                     always may; not-yet-sent (no qualifying message) → owner-only.
    * group_avatar → the asset's conversation_id → membership.
    * user_avatar  → same app + authenticated.
  Every failure → 404 (no existence reveal, never 403). No DB: the media/message/conversation clients are
  stubbed, so these prove the authorization + that a client-supplied object_key is ignored.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.MediaController

  # @app / @convo live in the stub modules below (nested modules have their own attribute scope).
  @member "22222222-2222-4222-8222-222222222222"
  @stranger "33333333-3333-4333-8333-333333333333"
  @former "66666666-6666-4666-8666-666666666666"
  @owner "77777777-7777-4777-8777-777777777777"
  # message media that HAS been sent (maps to the stubbed conversation)
  @msg_media "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  # message media uploaded but NOT sent (no message row)
  @unsent_media "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @avatar_media "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  @group_media "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
  # any media_id NOT in the caller's app → get_asset 404
  @cross_media "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
  # SEALED media (E2EE attachment): bound to a conversation at upload; NO message ever references it.
  @sealed_media "ffffffff-ffff-4fff-8fff-ffffffffffff"
  # A sealed asset with no conversation_id (older upload) → owner-only.
  @sealed_orphan "12121212-1212-4121-8121-121212121212"

  defmodule AuthStub do
    @moduledoc false
    @app "44444444-4444-4444-8444-444444444444"
    def current_session(%{"authorization" => "Bearer " <> user_id}) when user_id != "",
      do: {:ok, %{user_id: user_id, app_id: @app}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule MediaStub do
    @moduledoc false
    @app "44444444-4444-4444-8444-444444444444"
    @owner "77777777-7777-4777-8777-777777777777"
    @convo "11111111-1111-4111-8111-111111111111"
    @msg_media "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    @unsent_media "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    @avatar_media "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    @group_media "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    @sealed_media "ffffffff-ffff-4fff-8fff-ffffffffffff"
    @sealed_orphan "12121212-1212-4121-8121-121212121212"

    # get_asset is scoped by (media_id, app_id): only assets in the caller's app resolve; anything else
    # (unknown id, another tenant's id) → :not_found. Only assets that belong to @app are matched here.
    def get_asset(%{"media_id" => @msg_media, "app_id" => @app}),
      do: ok("message", @owner, nil, @msg_media)

    def get_asset(%{"media_id" => @unsent_media, "app_id" => @app}),
      do: ok("message", @owner, nil, @unsent_media)

    def get_asset(%{"media_id" => @avatar_media, "app_id" => @app}),
      do: ok("user_avatar", @owner, nil, @avatar_media)

    def get_asset(%{"media_id" => @group_media, "app_id" => @app}),
      do: ok("group_avatar", @owner, @convo, @group_media)

    # The E2EE attachment: purpose sealed_media, carrying the conversation it was uploaded for.
    def get_asset(%{"media_id" => @sealed_media, "app_id" => @app}),
      do: ok("sealed_media", @owner, @convo, @sealed_media)

    def get_asset(%{"media_id" => @sealed_orphan, "app_id" => @app}),
      do: ok("sealed_media", @owner, nil, @sealed_orphan)

    def get_asset(_), do: {:error, :not_found}

    # NOTE: never receives object_key — the controller passes only media_id + app_id. The URL is derived
    # from the media_id (the row's key), so a client-supplied object_key can't influence it.
    def get_download_url(%{"media_id" => media_id, "app_id" => @app}) do
      {:ok,
       %{
         media_id: media_id,
         download_url: "https://minio.local/get/" <> media_id,
         expires_at: "2026-07-09T00:00:00Z",
         mime_type: "image/png"
       }}
    end

    defp ok(purpose, owner, conversation_id, media_id) do
      {:ok,
       %{
         media_id: media_id,
         purpose: purpose,
         owner_user_id: owner,
         conversation_id: conversation_id
       }}
    end
  end

  defmodule MessageStub do
    @moduledoc false
    @member "22222222-2222-4222-8222-222222222222"
    @owner "77777777-7777-4777-8777-777777777777"
    @msg_media "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    # The owner-anchored rule: for the SENT media, only @member sits in a conversation holding the
    # owner's send (a stranger AND a former participant — left_at — both fail the active-membership
    # probe); the unsent asset has no qualifying message for anyone. The OWNER never reaches here
    # (the fast-path in MediaAuthz short-circuits).
    def media_download_allowed(%{
          "media_id" => @msg_media,
          "owner_user_id" => @owner,
          "viewer_user_id" => @member
        }),
        do: {:ok, %{allowed: true}}

    def media_download_allowed(_attrs), do: {:ok, %{allowed: false}}
  end

  defmodule ConvStub do
    @moduledoc false
    @member "22222222-2222-4222-8222-222222222222"
    # Only @member is an active participant; a stranger AND a former participant (left_at set) both fail.
    def get_conversation(%{"user_id" => @member}), do: {:ok, %{}}
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

  defp download(user_id, media_id, extra_params \\ %{}) do
    conn =
      :get
      |> conn("/api/v1/media/#{media_id}/download", %{})
      |> put_req_header("authorization", "Bearer " <> user_id)

    MediaController.download(conn, Map.merge(%{"media_id" => media_id}, extra_params))
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp assert_opaque_404(conn) do
    assert conn.status == 404
    refute conn.status == 403
    assert body(conn)["error"]["code"] == "media.not_found"
  end

  # --- message media ---------------------------------------------------------------------------------

  test "participant downloads message-media → 200, download_url present, object_key ABSENT" do
    conn = download(@member, @msg_media)
    assert conn.status == 200
    b = body(conn)
    assert b["download_url"] == "https://minio.local/get/" <> @msg_media
    refute Map.has_key?(b, "object_key")
  end

  test "NON-participant downloads the same media_id → 404 (the test that failed before the fix)" do
    assert_opaque_404(download(@stranger, @msg_media))
  end

  test "former participant (left_at set) → 404" do
    assert_opaque_404(download(@former, @msg_media))
  end

  test "another tenant's media_id → 404" do
    assert_opaque_404(download(@member, @cross_media))
  end

  test "owner downloads their own not-yet-sent asset (no message row) → 200" do
    conn = download(@owner, @unsent_media)
    assert conn.status == 200
  end

  test "non-owner downloads a not-yet-sent asset → 404" do
    assert_opaque_404(download(@member, @unsent_media))
  end

  test "a client-supplied object_key is IGNORED — the URL is signed for the ROW's key" do
    # A participant passes a DIFFERENT (attacker) object_key; the response URL still reflects the row.
    conn = download(@member, @msg_media, %{"object_key" => "media/victim/secret/steal.png"})
    assert conn.status == 200
    b = body(conn)
    assert b["download_url"] == "https://minio.local/get/" <> @msg_media
    refute Map.has_key?(b, "object_key")
  end

  # --- avatars ---------------------------------------------------------------------------------------

  test "user_avatar in the same app → 200" do
    assert download(@member, @avatar_media).status == 200
  end

  test "user_avatar whose asset is in ANOTHER app → 404" do
    # @avatar_media resolves only for @app; a media_id absent from the caller's app is get_asset 404.
    assert_opaque_404(download(@member, @cross_media))
  end

  test "group_avatar: a member → 200" do
    assert download(@member, @group_media).status == 200
  end

  test "group_avatar: a non-member → 404" do
    assert_opaque_404(download(@stranger, @group_media))
  end

  # --- SEALED MEDIA (E2EE attachments) ---------------------------------------------------------------
  #
  # THE PRODUCTION OUTAGE THESE PIN. sealed_media used to route to the message-media rule, whose oracle
  # asks "is there a message referencing this media_id whose sender is the owner?". A sealed message's
  # media_id column is forced NULL (the descriptor rides inside the encrypted frame), so that oracle
  # finds nothing and denies EVERY recipient — every encrypted attachment 404'd while E2EE was
  # default-on. The owner short-circuit hid it from the sender, which is why it presented as
  # purpose-specific rather than transport-specific.
  #
  # Note the MessageStub above answers allowed:false for @sealed_media — exactly as the real oracle
  # does. So if these ever route back through the message rule, they fail.

  test "a conversation PARTICIPANT can download sealed media → 200" do
    conn = download(@member, @sealed_media)

    assert conn.status == 200
    assert body(conn)["download_url"] == "https://minio.local/get/" <> @sealed_media
  end

  test "the OWNER can download their own sealed media → 200" do
    assert download(@owner, @sealed_media).status == 200
  end

  test "a NON-PARTICIPANT gets an opaque 404 for sealed media" do
    assert_opaque_404(download(@stranger, @sealed_media))
  end

  test "a FORMER participant (left the conversation) gets 404 — membership must be ACTIVE" do
    assert_opaque_404(download(@former, @sealed_media))
  end

  test "sealed media in ANOTHER tenant → 404 (get_asset is app-scoped, before any authz)" do
    assert_opaque_404(download(@member, @cross_media))
  end

  test "a sealed asset with NO conversation_id is owner-only" do
    # Nothing to check membership against, so the safe default: the owner, and nobody else.
    assert download(@owner, @sealed_orphan).status == 200
    assert_opaque_404(download(@member, @sealed_orphan))
    assert_opaque_404(download(@stranger, @sealed_orphan))
  end

  test "sealed media does NOT consult the message oracle — it cannot, there is no message row" do
    # The stub denies @sealed_media for everyone; a 200 for the participant proves the decision came
    # from conversation membership instead. This is the mutation point: route sealed_media back to
    # authorize_message_media and this test goes red with a 404.
    assert download(@member, @sealed_media).status == 200
  end
end
