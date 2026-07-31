defmodule ApiGatewayWeb.MessagePollControllerTest do
  @moduledoc """
  Poll endpoints (Docker-free; Auth/Conversation/Message clients stubbed). Proves the HTTP contract:
  vote → 200 {message_id, poll} AND a `poll_updated` broadcast on the CONVERSATION topic (the reaction
  transport — the socket is mounted on this endpoint); a non-member → 403 and NO broadcast; vote error
  codes (polls.invalid_option / polls.single_choice); create's poll validation codes surface as
  polls.<failure>; GET poll-votes → the uncapped lists; 401. The SQL (semantics, cold-load == live) is
  proven in MessageService.PollsTest.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.MessageController

  @conv "22222222-2222-4222-8222-222222222222"
  @msg "99999999-9999-4999-8999-999999999999"
  @me "11111111-1111-4111-8111-111111111111"

  @poll %{
    question: "Lunch where?",
    allows_multiple: false,
    options: [
      %{id: "o1", text: "Sushi", count: 1, voter_ids: [@me]},
      %{id: "o2", text: "Pizza", count: 0, voter_ids: []}
    ],
    total_voters: 1
  }

  defmodule AuthStub do
    def current_session(%{"authorization" => "Bearer " <> uid}) when uid != "",
      do: {:ok, %{user_id: uid, app_id: "app1"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConvStub do
    # Membership: only @me is a member.
    def get_conversation(%{"user_id" => "11111111-1111-4111-8111-111111111111"}), do: {:ok, %{}}
    def get_conversation(_), do: {:error, :forbidden}
    def authorize_send(_attrs), do: {:ok, %{authorized: true}}
  end

  defmodule MsgStub do
    @msg "99999999-9999-4999-8999-999999999999"
    @me "11111111-1111-4111-8111-111111111111"

    @poll %{
      question: "Lunch where?",
      allows_multiple: false,
      options: [
        %{id: "o1", text: "Sushi", count: 1, voter_ids: [@me]},
        %{id: "o2", text: "Pizza", count: 0, voter_ids: []}
      ],
      total_voters: 1
    }

    def vote_poll(%{"option_ids" => ["o9"]}), do: {:error, :poll_invalid_option}
    def vote_poll(%{"option_ids" => ["o1", "o2"]}), do: {:error, :poll_single_choice}
    def vote_poll(%{"message_id" => @msg}), do: {:ok, %{message_id: @msg, poll: @poll}}
    def vote_poll(_attrs), do: {:error, :message_not_found}

    def list_poll_votes(%{"message_id" => @msg}), do: {:ok, %{message_id: @msg, poll: @poll}}
    def list_poll_votes(_attrs), do: {:error, :message_not_found}

    # Create: the body text marks which poll-validation error the domain would return.
    def create_message(%{"body" => "bad-question"}), do: {:error, :poll_invalid_question}
    def create_message(%{"body" => "dup"}), do: {:error, :poll_duplicate_option}
    def create_message(attrs), do: {:ok, %{message_id: @msg, body: attrs["body"]}}
  end

  setup do
    prev = %{
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      conv: Application.get_env(:shared_infra, :conversation_client_adapter),
      msg: Application.get_env(:shared_infra, :message_client_adapter),
      persistence: Application.get_env(:message_service, :message_persistence)
    }

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)

    # The create action branches on persistence; force the DB path (create_message + the poll codes).
    Application.put_env(:message_service, :message_persistence, true)

    on_exit(fn ->
      restore(:auth_client_adapter, prev.auth)
      restore(:conversation_client_adapter, prev.conv)
      restore(:message_client_adapter, prev.msg)

      if prev.persistence == nil,
        do: Application.delete_env(:message_service, :message_persistence),
        else: Application.put_env(:message_service, :message_persistence, prev.persistence)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  defp authed(method, token \\ @me) do
    method |> conn("/x", %{}) |> put_req_header("authorization", "Bearer #{token}")
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp vote(option_ids, token \\ @me, message_id \\ @msg) do
    MessageController.vote(authed(:post, token), %{
      "conversation_id" => @conv,
      "message_id" => message_id,
      "option_ids" => option_ids
    })
  end

  test "vote → 200 {message_id, poll} AND poll_updated on the CONVERSATION topic with the same aggregate" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "conversation:#{@conv}")

    conn = vote(["o1"])
    assert conn.status == 200

    response = body(conn)
    assert response["message_id"] == @msg
    assert response["poll"]["total_voters"] == 1
    assert [%{"id" => "o1", "count" => 1, "voter_ids" => [@me]} | _] = response["poll"]["options"]

    # The live event: same transport reactions use (the socket is mounted on this endpoint), whole
    # aggregate, viewer-independent.
    assert_receive %Phoenix.Socket.Broadcast{
                     event: "poll_updated",
                     topic: "conversation:" <> _,
                     payload: %{message_id: @msg, poll: poll}
                   },
                   1000

    assert poll.total_voters == 1
  end

  test "a NON-member → 403 and NO broadcast" do
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "conversation:#{@conv}")

    conn = vote(["o1"], "55555555-5555-4555-8555-555555555555")
    assert conn.status == 403

    refute_receive %Phoenix.Socket.Broadcast{event: "poll_updated"}, 200
  end

  test "vote error codes: unknown option → polls.invalid_option; two ids on single-choice → polls.single_choice" do
    invalid = vote(["o9"])
    assert invalid.status == 400
    assert body(invalid)["error"]["code"] == "polls.invalid_option"

    single = vote(["o1", "o2"])
    assert single.status == 400
    assert body(single)["error"]["code"] == "polls.single_choice"

    unknown = vote(["o1"], @me, "88888888-8888-4888-8888-888888888888")
    assert unknown.status == 404
  end

  test "create surfaces each poll validation failure as its SPECIFIC polls.* code" do
    for {marker, code} <- [
          {"bad-question", "polls.invalid_question"},
          {"dup", "polls.duplicate_option"}
        ] do
      conn =
        MessageController.create(authed(:post), %{
          "conversation_id" => @conv,
          "message_type" => "poll",
          "body" => marker,
          "metadata" => %{}
        })

      assert conn.status == 400
      assert body(conn)["error"]["code"] == code
    end
  end

  test "GET poll-votes → 200 with the (uncapped) lists; membership-gated" do
    conn =
      MessageController.poll_votes(authed(:get), %{
        "conversation_id" => @conv,
        "message_id" => @msg
      })

    assert conn.status == 200
    assert body(conn)["poll"]["options"] |> length() == 2

    outsider =
      MessageController.poll_votes(authed(:get, "55555555-5555-4555-8555-555555555555"), %{
        "conversation_id" => @conv,
        "message_id" => @msg
      })

    assert outsider.status == 403
  end

  test "no session → 401" do
    assert vote(["o1"], "").status == 401
  end
end
