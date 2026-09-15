defmodule ApiGatewayWeb.TimelineMediaLinksAuthzTest do
  @moduledoc """
  The timeline's inline download links (`metadata.media.download_url`, minted by message-service
  for every page it answers) reach ONLY members: the gateway's membership check runs BEFORE the
  message client is asked for the page, so a non-member gets a 403 with no page — and therefore no
  presigned URL — at all. This pins that ordering against the media-link payload specifically.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.MessageController

  @conversation "11111111-1111-4111-8111-111111111111"
  @member "22222222-2222-4222-8222-222222222222"
  @outsider "33333333-3333-4333-8333-333333333333"
  @url "https://minio.test/chat-media/media/u/a/photo-a.png?X-Amz-Expires=900"

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer member"}),
      do: {:ok, %{user_id: "22222222-2222-4222-8222-222222222222", app_id: "app-1"}}

    def current_session(%{"authorization" => "Bearer outsider"}),
      do: {:ok, %{user_id: "33333333-3333-4333-8333-333333333333", app_id: "app-1"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConvStub do
    @moduledoc false
    # Membership is what the conversation service answers: the member sees the row, the outsider
    # gets the not-a-member refusal.
    def get_conversation(%{"user_id" => "22222222-2222-4222-8222-222222222222"}),
      do: {:ok, %{conversation_id: "11111111-1111-4111-8111-111111111111"}}

    def get_conversation(_), do: {:error, :conversation_membership_forbidden}
  end

  defmodule MsgStub do
    @moduledoc false
    # Records who the page was fetched for, and answers a media row WITH its inline link.
    def list_messages(attrs) do
      send(self(), {:list_messages, attrs["viewer_user_id"]})

      {:ok,
       %{
         conversation_id: "11111111-1111-4111-8111-111111111111",
         messages: [
           %{
             message_id: "m-1",
             message_type: "media",
             media_id: "aaaaaaaa-0000-4000-8000-00000000000a",
             metadata: %{
               "media_id" => "aaaaaaaa-0000-4000-8000-00000000000a",
               "media" => %{
                 "download_url" =>
                   "https://minio.test/chat-media/media/u/a/photo-a.png?X-Amz-Expires=900",
                 "download_url_expires_at" => "2026-09-15T12:15:00Z"
               }
             }
           }
         ],
         next_cursor: nil
       }}
    end
  end

  setup do
    keys = [:auth_client_adapter, :conversation_client_adapter, :message_client_adapter]
    prev = for k <- keys, into: %{}, do: {k, Application.get_env(:shared_infra, k)}
    prev_persist = Application.get_env(:message_service, :message_persistence)

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)
    Application.put_env(:message_service, :message_persistence, true)

    on_exit(fn ->
      for {k, v} <- prev do
        if v,
          do: Application.put_env(:shared_infra, k, v),
          else: Application.delete_env(:shared_infra, k)
      end

      if prev_persist,
        do: Application.put_env(:message_service, :message_persistence, prev_persist),
        else: Application.delete_env(:message_service, :message_persistence)
    end)

    :ok
  end

  test "a MEMBER's page carries the inline link" do
    conn = index("member")
    assert conn.status == 200
    assert %{"messages" => [row]} = Jason.decode!(conn.resp_body)
    assert row["metadata"]["media"]["download_url"] == @url

    assert Map.keys(row["metadata"]["media"]) |> Enum.sort() == [
             "download_url",
             "download_url_expires_at"
           ]

    assert_received {:list_messages, @member}
  end

  test "a NON-MEMBER gets 403 and NO page — the presigned URL never leaves the server (MUT-4)" do
    conn = index("outsider")
    assert conn.status == 403
    refute conn.resp_body =~ "download_url"
    refute conn.resp_body =~ "minio.test"
    # The page was never even requested for the outsider: authz runs before the message client.
    refute_received {:list_messages, @outsider}
  end

  defp index(bearer) do
    :get
    |> conn("/x", %{"conversation_id" => @conversation})
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> MessageController.index(%{"conversation_id" => @conversation})
  end
end
