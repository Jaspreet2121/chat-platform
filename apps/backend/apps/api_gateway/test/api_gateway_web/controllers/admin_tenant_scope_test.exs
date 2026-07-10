defmodule ApiGatewayWeb.AdminTenantScopeTest do
  @moduledoc """
  The admin console is first-party only (tenant-zero). These no-DB gateway tests prove: the content viewer
  and admin message-delete 404 on a conversation outside tenant-zero (before any content is read/deleted),
  every scoped query is passed app_id = tenant-zero, and enrich_media won't presign a non-tenant-zero asset.
  DB-level scoping (list_users/analytics/roles filtering by app_id) is covered by the postgres_integration
  companion test.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.{AdminAnalyticsController, AdminContentController, AdminModerationController}

  @default SharedInfra.Tenancy.default_app_id()
  # @integrator lives in ConvStub (nested modules have their own attribute scope).
  @convo "11111111-1111-4111-8111-111111111111"
  @integrator_convo "22222222-2222-4222-8222-222222222222"
  @tenant_media "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @integrator_media "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

  defmodule ConvStub do
    @moduledoc false
    @default SharedInfra.Tenancy.default_app_id()
    @integrator "869819fa-0000-4000-8000-000000000000"
    @convo "11111111-1111-4111-8111-111111111111"
    @integrator_convo "22222222-2222-4222-8222-222222222222"

    def get_conversation_app(%{"conversation_id" => @convo}), do: {:ok, %{app_id: @default}}
    def get_conversation_app(%{"conversation_id" => @integrator_convo}), do: {:ok, %{app_id: @integrator}}
    def get_conversation_app(_), do: {:error, :not_found}

    # Echo the app_id the controller injected so the test can assert it's tenant-zero.
    def admin_list_conversations(attrs), do: {:ok, %{conversations: [], echo_app_id: attrs["app_id"]}}
    def admin_user_conversations(attrs), do: {:ok, %{conversations: [], echo_app_id: attrs["app_id"]}}
  end

  defmodule MsgStub do
    @moduledoc false
    def list_messages(_attrs), do: {:ok, %{messages: []}}
    # If this is ever reached for an integrator conversation the gate failed → make it obvious.
    def admin_delete_message(_attrs), do: {:ok, %{deleted: true, LEAKED: true}}
    def analytics_overview(attrs), do: {:ok, %{echo_app_id: attrs["app_id"]}}
    def analytics_timeseries(attrs), do: {:ok, %{echo_app_id: attrs["app_id"]}}
  end

  defmodule AuthStub do
    @moduledoc false
    def list_user_summaries(_attrs), do: {:ok, %{summaries: []}}
    def write_audit(_attrs), do: {:ok, %{written: true}}
  end

  defmodule MediaStub do
    @moduledoc false
    @default SharedInfra.Tenancy.default_app_id()
    @tenant_media "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    # Presign only a tenant-zero asset; an integrator asset (row in another app) → not_found → no URL.
    def get_download_url(%{"media_id" => @tenant_media, "app_id" => @default, "purpose" => "message"}),
      do: {:ok, %{download_url: "https://minio.local/get/" <> @tenant_media}}

    def get_download_url(_), do: {:error, :not_found}
  end

  setup do
    prev = %{
      conv: Application.get_env(:shared_infra, :conversation_client_adapter),
      msg: Application.get_env(:shared_infra, :message_client_adapter),
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      media: Application.get_env(:shared_infra, :media_client_adapter)
    }

    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)

    on_exit(fn ->
      restore(:conversation_client_adapter, prev.conv)
      restore(:message_client_adapter, prev.msg)
      restore(:auth_client_adapter, prev.auth)
      restore(:media_client_adapter, prev.media)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  defp admin_conn do
    conn(:get, "/")
    |> assign(:admin_session, %{user_id: "admin-1", permissions: ["content.read"]})
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  # --- content viewer -------------------------------------------------------------------------------

  test "content viewer: an integrator conversation_id → 404 (no content read, no audit)" do
    conn = AdminContentController.messages(admin_conn(), %{"id" => @integrator_convo})
    assert conn.status == 404
    assert body(conn)["error"]["code"] == "admin.not_found"
  end

  test "content viewer: a tenant-zero conversation → 200" do
    conn = AdminContentController.messages(admin_conn(), %{"id" => @convo})
    assert conn.status == 200
    assert body(conn)["conversation_id"] == @convo
  end

  test "content viewer: an unknown conversation → 404" do
    conn = AdminContentController.messages(admin_conn(), %{"id" => Ecto.UUID.generate()})
    assert conn.status == 404
  end

  test "conversation list is scoped to tenant-zero" do
    conn = AdminContentController.conversations(admin_conn(), %{})
    assert body(conn)["echo_app_id"] == @default
  end

  test "a user's conversations list is scoped to tenant-zero" do
    conn = AdminContentController.user_conversations(admin_conn(), %{"id" => Ecto.UUID.generate()})
    assert body(conn)["echo_app_id"] == @default
  end

  # --- message delete -------------------------------------------------------------------------------

  test "admin message-delete on an integrator conversation → 404, delete NOT performed" do
    conn =
      AdminModerationController.delete_message(admin_conn(), %{
        "id" => "msg-1",
        "conversation_id" => @integrator_convo
      })

    assert conn.status == 404
    # The MsgStub would return a LEAKED:true body if admin_delete_message had been called.
    refute body(conn)["LEAKED"] == true
  end

  # --- analytics ------------------------------------------------------------------------------------

  test "analytics overview is scoped to tenant-zero" do
    conn = AdminAnalyticsController.overview(admin_conn(), %{})
    assert body(conn)["echo_app_id"] == @default
  end

  test "analytics timeseries is scoped to tenant-zero" do
    conn = AdminAnalyticsController.timeseries(admin_conn(), %{"days" => "7"})
    assert body(conn)["echo_app_id"] == @default
  end

  # --- enrich_media ---------------------------------------------------------------------------------

  test "enrich_media presigns a tenant-zero asset but NOT an integrator asset" do
    tenant_msg = %{message_type: "media", media_id: @tenant_media}
    integrator_msg = %{message_type: "media", media_id: @integrator_media}

    assert AdminContentController.enrich_media(tenant_msg, @default).download_url =~ @tenant_media
    refute Map.has_key?(AdminContentController.enrich_media(integrator_msg, @default), :download_url)
  end
end
