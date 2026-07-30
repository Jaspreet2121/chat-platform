defmodule ApiGatewayWeb.MessageInfoControllerTest do
  @moduledoc """
  GET .../messages/:message_id/info (Docker-free; Auth/Conversation/User/Message clients stubbed). Proves
  the HTTP contract: sender → 200 with enriched read+delivered lists; non-sender member → 403
  messages.not_sender; NON-member → 404 (existence-hiding, not the usual membership 403); unknown message →
  404; a DEPARTED/unresolvable profile still yields a {user_id, display_name: nil} entry (never a blank
  crash); read_hidden passes through (the sender's OWN setting — client copy: "You have read receipts
  turned off"); no session → 401. The SQL (privacy split, tombstone, bounded queries) is proven in
  MessageService.MessageInfoTest.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.MessageController

  @conv "22222222-2222-4222-8222-222222222222"
  @msg "99999999-9999-4999-8999-999999999999"
  @sender "11111111-1111-4111-8111-111111111111"
  @member "33333333-3333-4333-8333-333333333333"
  @gone "77777777-7777-4777-8777-777777777777"

  defmodule AuthStub do
    def current_session(%{"authorization" => "Bearer " <> uid}) when uid != "",
      do: {:ok, %{user_id: uid, app_id: "app1"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConvStub do
    # Membership: sender + member are in; anyone else is not (authorize_membership fails → 404).
    def get_conversation(%{"user_id" => uid}) when uid in ["11111111-1111-4111-8111-111111111111", "33333333-3333-4333-8333-333333333333"],
      do: {:ok, %{conversation_id: "22222222-2222-4222-8222-222222222222", participants: []}}

    def get_conversation(_), do: {:error, :conversation_membership_forbidden}

    # ProfilePresenter's block half — nobody is blocked in these tests.
    def either_blocked?(_attrs), do: {:ok, %{blocked: false}}
    def shares_conversation?(_attrs), do: {:ok, %{shares: true}}
  end

  defmodule UserStub do
    @gone "77777777-7777-4777-8777-777777777777"

    # The DEPARTED-account case: no profile resolves — the entry must degrade, not crash.
    def get_public_profile(%{"user_id" => @gone}), do: {:error, :profile_not_found}

    def get_public_profile(%{"user_id" => uid}),
      do: {:ok, %{user_id: uid, display_name: "Reader #{String.slice(uid, 0, 2)}", avatar_media_id: nil, bio: nil}}

    def get_privacy(_attrs), do: {:ok, %{profile_photo_visibility: "everyone"}}
  end

  defmodule MsgStub do
    @msg "99999999-9999-4999-8999-999999999999"
    @sender "11111111-1111-4111-8111-111111111111"
    @member "33333333-3333-4333-8333-333333333333"
    @gone "77777777-7777-4777-8777-777777777777"

    def message_info(%{"message_id" => mid}) when mid != @msg, do: {:error, :message_not_found}

    def message_info(%{"viewer_user_id" => viewer}) when viewer != @sender, do: {:error, :not_sender}

    def message_info(_attrs) do
      {:ok,
       %{
         conversation_id: "22222222-2222-4222-8222-222222222222",
         message_id: @msg,
         sender_user_id: @sender,
         read: [%{user_id: @member, read_at: "2026-07-30T10:00:00Z"}],
         # The departed reader (unresolvable profile) sits in delivered.
         delivered: [%{user_id: @gone, delivered_at: "2026-07-30T09:00:00Z"}],
         read_hidden: false
       }}
    end
  end

  setup do
    prev = %{
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      conv: Application.get_env(:shared_infra, :conversation_client_adapter),
      user: Application.get_env(:shared_infra, :user_client_adapter),
      msg: Application.get_env(:shared_infra, :message_client_adapter)
    }

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)

    on_exit(fn ->
      restore(:auth_client_adapter, prev.auth)
      restore(:conversation_client_adapter, prev.conv)
      restore(:user_client_adapter, prev.user)
      restore(:message_client_adapter, prev.msg)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  defp get_info(token, message_id \\ @msg) do
    :get
    |> conn("/x")
    |> put_req_header("authorization", "Bearer #{token}")
    |> MessageController.info(%{"conversation_id" => @conv, "message_id" => message_id})
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "SENDER → 200: read enriched with display_name; departed reader present in delivered with name nil" do
    conn = get_info(@sender)
    assert conn.status == 200

    b = body(conn)
    assert b["read_hidden"] == false

    assert [read_entry] = b["read"]
    assert read_entry["user_id"] == @member
    assert read_entry["read_at"] == "2026-07-30T10:00:00Z"
    assert read_entry["display_name"] == "Reader 33"

    # The departed reader: PRESENT (receipts are history), degraded to a nameless-but-renderable entry.
    assert [gone_entry] = b["delivered"]
    assert gone_entry["user_id"] == @gone
    assert gone_entry["delivered_at"] == "2026-07-30T09:00:00Z"
    assert gone_entry["display_name"] == nil
    assert gone_entry["avatar_url"] == nil
  end

  test "a NON-SENDER member → 403 messages.not_sender" do
    conn = get_info(@member)
    assert conn.status == 403
    assert body(conn)["error"]["code"] == "messages.not_sender"
  end

  test "a NON-member → 404 (membership failure is existence-hiding here, not 403)" do
    conn = get_info("55555555-5555-4555-8555-555555555555")
    assert conn.status == 404
  end

  test "an unknown message → 404" do
    conn = get_info(@sender, "88888888-8888-4888-8888-888888888888")
    assert conn.status == 404
  end

  test "no session → 401" do
    conn = get_info("")
    assert conn.status == 401
  end
end
