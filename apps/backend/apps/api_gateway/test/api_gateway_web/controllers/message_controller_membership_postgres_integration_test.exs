defmodule ApiGatewayWeb.MessageControllerMembershipPostgresIntegrationTest do
  # HTTP message create/list must reject non-participants of a conversation.
  #
  # NOTE on coverage + hard rule #10 (no cross-repo positive DB tests touching the
  # SAME FK rows): these are NEGATIVE tests where the requester (AuthRepo session
  # user) is a DIFFERENT row from the seeded conversation member (ConversationRepo,
  # FK to users_auth). Different rows across repos => no cross-repo sandbox lock.
  # The POSITIVE "member is allowed" HTTP path is intentionally NOT a DB test here:
  # it would require the same user row in both AuthRepo and ConversationRepo. The
  # allow-path wiring is exercised Docker-free by message_controller_media_test
  # (conversation persistence off => placeholder membership {:ok} => create 201),
  # and get_conversation's positive participant check is covered by conversation_service's
  # own postgres_integration tests.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AuthService.Repo, as: AuthRepo
  alias AuthService.Schemas.DeviceSession
  alias AuthService.Schemas.UserAuth
  alias AuthService.Tokens
  alias ConversationService.Repo, as: ConversationRepo
  alias MessageService.MessageStore

  @tag :postgres_integration
  test "POST messages is rejected for a non-participant of the conversation" do
    fixture = create_session_fixture!()
    token = create_access_token!(fixture)
    conversation_id = seed_conversation_without!(fixture.user_id)

    conn =
      json_request(
        :post,
        "/api/v1/conversations/#{conversation_id}/messages",
        %{"message_type" => "text", "body" => "I should not be here"},
        token
      )

    assert conn.status == 403
    assert %{"error" => %{"code" => "message.forbidden"}} = Jason.decode!(conn.resp_body)
  end

  @tag :postgres_integration
  test "GET messages is rejected for a non-participant of the conversation" do
    fixture = create_session_fixture!()
    token = create_access_token!(fixture)
    conversation_id = seed_conversation_without!(fixture.user_id)

    conn =
      authenticated_get("/api/v1/conversations/#{conversation_id}/messages", token)

    assert conn.status == 403
    assert %{"error" => %{"code" => "message.forbidden"}} = Jason.decode!(conn.resp_body)
  end

  setup do
    previous_auth_session = Application.get_env(:auth_service, :session_persistence, false)

    previous_conversation =
      Application.get_env(:conversation_service, :conversation_persistence, false)

    previous_message = Application.get_env(:message_service, :message_persistence, false)

    previous_adapter =
      Application.get_env(:message_service, :message_store_adapter, MessageStore.QueryPlanAdapter)

    Application.put_env(:auth_service, :session_persistence, true)
    Application.put_env(:conversation_service, :conversation_persistence, true)
    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:message_service, :message_store_adapter, MessageStore.InMemoryAdapter)

    start_repo!(AuthRepo)
    start_repo!(ConversationRepo)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(AuthRepo)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(ConversationRepo)
    start_in_memory_store!()
    MessageStore.InMemoryAdapter.reset()

    on_exit(fn ->
      MessageStore.InMemoryAdapter.reset()
      Application.put_env(:auth_service, :session_persistence, previous_auth_session)
      Application.put_env(:conversation_service, :conversation_persistence, previous_conversation)
      Application.put_env(:message_service, :message_persistence, previous_message)
      Application.put_env(:message_service, :message_store_adapter, previous_adapter)
    end)

    :ok
  end

  # Seeds an active conversation whose only participant is some OTHER user (not
  # `requester_id`). The member's users_auth row is inserted via ConversationRepo so
  # the conversations.created_by / conversation_participants.user_id FKs are satisfied
  # within ConversationRepo's sandbox connection.
  defp seed_conversation_without!(_requester_id) do
    # member_id is a fresh UUID, distinct from the requester by construction.
    member_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    {1, _} =
      ConversationRepo.insert_all(UserAuth, [
        %{
          id: member_id,
          phone_number: unique_phone_number(),
          status: "active",
          created_at: now,
          updated_at: now
        }
      ])

    {:ok, conversation} =
      ConversationService.Conversations.create_conversation(%{
        "type" => "group",
        "created_by" => member_id,
        "participant_user_ids" => [member_id]
      })

    conversation.conversation_id
  end

  defp json_request(method, path, params, token) do
    method
    |> conn(path, Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> ApiGatewayWeb.Endpoint.call([])
  end

  defp authenticated_get(path, token) do
    :get
    |> conn(path)
    |> put_req_header("authorization", "Bearer #{token}")
    |> ApiGatewayWeb.Endpoint.call([])
  end

  defp create_session_fixture! do
    user_id = Ecto.UUID.generate()
    session_id = Ecto.UUID.generate()
    device_id = "message-member-device-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now()

    {:ok, user} =
      %UserAuth{}
      |> UserAuth.changeset(%{
        "id" => user_id,
        "phone_number" => unique_phone_number(),
        "status" => "active"
      })
      |> AuthRepo.insert()

    {:ok, device_session} =
      %DeviceSession{}
      |> DeviceSession.changeset(%{
        "id" => session_id,
        "user_id" => user.id,
        "device_id" => device_id,
        "device_name" => "Membership Device",
        "platform" => "ios",
        "refresh_token_hash" => Tokens.hash_token("membership-refresh-#{device_id}"),
        "last_seen_at" => now
      })
      |> AuthRepo.insert()

    %{user_id: user.id, session_id: device_session.id, device_id: device_session.device_id}
  end

  defp create_access_token!(fixture) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, Tokens.access_token_ttl_seconds(), :second)

    claims = %{
      "typ" => "access",
      "sub" => fixture.user_id,
      "sid" => fixture.session_id,
      "did" => fixture.device_id,
      "iat" => DateTime.to_unix(now),
      "exp" => DateTime.to_unix(expires_at),
      "jti" => Ecto.UUID.generate()
    }

    {:ok, token} = Tokens.sign_claims(claims)
    token
  end

  defp start_repo!(repo) do
    case repo.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end

  defp start_in_memory_store! do
    case MessageStore.InMemoryAdapter.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end

  defp unique_phone_number do
    "+1555#{System.unique_integer([:positive])}"
  end
end
