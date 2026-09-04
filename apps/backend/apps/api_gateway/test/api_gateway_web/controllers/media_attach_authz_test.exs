defmodule ApiGatewayWeb.MediaAttachAuthzTest do
  @moduledoc """
  A SENDER MAY ONLY ATTACH THEIR OWN MEDIA.

  THE HOLE THIS CLOSES. `/v1` has always validated a message's `media_id` (owner, tenant, status,
  purpose — V1.MessageController.validate_media/3); the first-party paths validated nothing, so a
  `media_id` from client params reached `create_message` unchecked. That let A attach B's asset to A's
  own message — and, because a view-once open PURGES the referenced media, let A destroy B's file
  outright with a second account to do the opening.

  Both halves are now closed and EITHER ALONE STOPS IT: this policy refuses the attach, and
  `MediaService.Media.purge_asset/1` refuses a purge whose expected owner does not match. This file
  locks the first half; `MediaService.MediaTest`'s purge-scoping cases lock the second.

  THE POLICY IS SHARED, and so is this test's reach: three first-party surfaces attach media —
  REST create, the broadcast fan-out, and the socket channel. All three call the SAME
  `SharedInfra.MediaAttachPolicy`, so the rule is asserted once here at the REST surface and by
  construction cannot differ on the others.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.MessageController

  @conversation "11111111-1111-4111-8111-111111111111"
  @sender "22222222-2222-4222-8222-222222222222"
  @victim "33333333-3333-4333-8333-333333333333"
  @app "44444444-4444-4444-8444-444444444444"

  @own_media "aaaaaaaa-0000-4000-8000-000000000001"
  @foreign_media "aaaaaaaa-0000-4000-8000-000000000002"
  @not_ready_media "aaaaaaaa-0000-4000-8000-000000000003"
  @wrong_purpose_media "aaaaaaaa-0000-4000-8000-000000000004"

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer sender"}),
      do:
        {:ok,
         %{
           user_id: "22222222-2222-4222-8222-222222222222",
           app_id: "44444444-4444-4444-8444-444444444444"
         }}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConvStub do
    @moduledoc false
    def get_conversation_app(_attrs), do: {:ok, %{}}

    def get_conversation(_attrs) do
      {:ok,
       %{
         app_id: "44444444-4444-4444-8444-444444444444",
         participants: [
           %{user_id: "22222222-2222-4222-8222-222222222222"},
           %{user_id: "33333333-3333-4333-8333-333333333333"}
         ]
       }}
    end

    def authorize_send(_attrs), do: {:ok, %{authorized: true}}

    def inbox_rows(%{"user_ids" => ids}) do
      {:ok,
       %{
         rows:
           Enum.map(
             ids,
             &%{
               user_id: &1,
               conversation_id: "11111111-1111-4111-8111-111111111111",
               unread_count: 0,
               updated_at: "2026-08-28T06:24:40.305000Z"
             }
           )
       }}
    end
  end

  defmodule MediaStub do
    @moduledoc false
    # One asset per failure mode, so each arm of the policy is exercised against a REAL lookup rather
    # than a blanket refusal.
    def get_asset(%{"media_id" => "aaaaaaaa-0000-4000-8000-000000000001"}),
      do:
        {:ok,
         %{
           media_id: "aaaaaaaa-0000-4000-8000-000000000001",
           owner_user_id: "22222222-2222-4222-8222-222222222222",
           status: "ready",
           purpose: "message"
         }}

    # The victim's asset — exists, ready, right purpose, WRONG OWNER.
    def get_asset(%{"media_id" => "aaaaaaaa-0000-4000-8000-000000000002"}),
      do:
        {:ok,
         %{
           media_id: "aaaaaaaa-0000-4000-8000-000000000002",
           owner_user_id: "33333333-3333-4333-8333-333333333333",
           status: "ready",
           purpose: "message"
         }}

    def get_asset(%{"media_id" => "aaaaaaaa-0000-4000-8000-000000000003"}),
      do:
        {:ok,
         %{
           media_id: "aaaaaaaa-0000-4000-8000-000000000003",
           owner_user_id: "22222222-2222-4222-8222-222222222222",
           status: "uploading",
           purpose: "message"
         }}

    def get_asset(%{"media_id" => "aaaaaaaa-0000-4000-8000-000000000004"}),
      do:
        {:ok,
         %{
           media_id: "aaaaaaaa-0000-4000-8000-000000000004",
           owner_user_id: "22222222-2222-4222-8222-222222222222",
           status: "ready",
           purpose: "user_avatar"
         }}

    def get_asset(_attrs), do: {:error, :not_found}
  end

  defmodule MsgStub do
    @moduledoc false
    def create_message(attrs) do
      {:ok,
       %{
         "message_id" => "m-1",
         "conversation_id" => Map.get(attrs, "conversation_id"),
         "sender_user_id" => Map.get(attrs, "sender_user_id"),
         "media_id" => Map.get(attrs, "media_id"),
         "message_type" => Map.get(attrs, "message_type"),
         "body" => Map.get(attrs, "body"),
         "status" => "active",
         "created_at" => "2026-08-28T06:28:01.117204Z"
       }}
    end
  end

  setup do
    prev = %{
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      conv: Application.get_env(:shared_infra, :conversation_client_adapter),
      msg: Application.get_env(:shared_infra, :message_client_adapter),
      media: Application.get_env(:shared_infra, :media_client_adapter),
      persist: Application.get_env(:message_service, :message_persistence, false)
    }

    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)

    on_exit(fn ->
      Application.put_env(:message_service, :message_persistence, prev.persist)
      restore(:auth_client_adapter, prev.auth)
      restore(:conversation_client_adapter, prev.conv)
      restore(:message_client_adapter, prev.msg)
      restore(:media_client_adapter, prev.media)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  defp send_media(media_id, extra \\ %{}) do
    body =
      Map.merge(
        %{"message_type" => "media", "body" => "photo", "media_id" => media_id},
        extra
      )

    :post
    |> conn("/api/v1/conversations/#{@conversation}/messages", %{})
    |> put_req_header("authorization", "Bearer sender")
    |> MessageController.create(Map.put(body, "conversation_id", @conversation))
  end

  defp body_of(conn), do: Jason.decode!(conn.resp_body)

  describe "the attach rule" do
    test "the sender's OWN ready message asset attaches (the happy path still works)" do
      conn = send_media(@own_media)
      assert conn.status == 201
    end

    test "ANOTHER USER'S asset is refused — the critical case" do
      conn = send_media(@foreign_media)

      assert conn.status == 422
      assert body_of(conn)["error"]["code"] == "message.media_invalid"
    end

    test "an asset that is not READY is refused (no verified bytes behind it yet)" do
      conn = send_media(@not_ready_media)
      assert conn.status == 422
    end

    test "a non-attachable PURPOSE is refused (a user_avatar may not be laundered onto a message)" do
      conn = send_media(@wrong_purpose_media)
      assert conn.status == 422
    end

    test "an UNKNOWN media_id is refused" do
      conn = send_media("aaaaaaaa-0000-4000-8000-00000000dead")
      assert conn.status == 422
    end

    test "NO EXISTENCE LEAK: unknown, foreign, not-ready and wrong-purpose are indistinguishable" do
      # If these ever diverge, the 422 body becomes an oracle for which media ids exist and who owns
      # them — the same reason every media download denial collapses to a single 404.
      bodies =
        for id <- [
              @foreign_media,
              @not_ready_media,
              @wrong_purpose_media,
              "aaaaaaaa-0000-4000-8000-00000000dead"
            ] do
          conn = send_media(id)
          {conn.status, body_of(conn)["error"]["code"], body_of(conn)["error"]["message"]}
        end

      assert length(Enum.uniq(bodies)) == 1,
             "attachment refusals differ by cause and leak which ids exist: #{inspect(Enum.uniq(bodies))}"
    end
  end

  describe "paths the rule must not disturb" do
    test "a TEXT message with no media_id is unaffected" do
      conn =
        :post
        |> conn("/api/v1/conversations/#{@conversation}/messages", %{})
        |> put_req_header("authorization", "Bearer sender")
        |> MessageController.create(%{
          "conversation_id" => @conversation,
          "message_type" => "text",
          "body" => "hello"
        })

      assert conn.status == 201
    end

    test "a SEALED message is not validated — its media_id is forced nil downstream anyway" do
      # Messages.media_id/2 discards media_id for sealed messages (the descriptor rides inside the
      # encrypted envelope), so validating a value about to be dropped could only reject a legitimate
      # send. A sealed send naming a FOREIGN id must therefore still succeed — nothing is attached.
      conn =
        :post
        |> conn("/api/v1/conversations/#{@conversation}/messages", %{})
        |> put_req_header("authorization", "Bearer sender")
        |> MessageController.create(%{
          "conversation_id" => @conversation,
          "message_type" => "sealed",
          "media_id" => @foreign_media,
          "metadata" => %{"envelopes" => [%{"device_id" => "d1", "ciphertext" => "AA=="}]}
        })

      assert conn.status in [200, 201]
    end
  end
end
