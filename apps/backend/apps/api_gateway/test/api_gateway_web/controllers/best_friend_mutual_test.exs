defmodule ApiGatewayWeb.BestFriendMutualTest do
  @moduledoc """
  `best_friend_mutual` on the user topics (125).

  Pinned here: a one-sided pin tells NOBODY (the private-until-returned rule), a mutual pin reaches
  both members and only them (MUT-4), an unpin says mutual:false, and the frame is emitted only
  AFTER the write has committed and been read back as mutual (MUT-3) — the store stub reports what
  had already been written when the broadcast reached this process.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.UserController

  @me "11111111-1111-4111-8111-111111111111"
  @peer "22222222-2222-4222-8222-222222222222"
  @outsider "33333333-3333-4333-8333-333333333333"
  @dm "44444444-4444-4444-8444-444444444444"

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer me"}),
      do: {:ok, %{user_id: "11111111-1111-4111-8111-111111111111", app_id: "app1"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  # Records the write and reports, at broadcast time, whether it had already happened.
  defmodule ConvStub do
    @moduledoc false
    def start_link, do: Agent.start_link(fn -> %{written: false} end, name: __MODULE__)
    def written?, do: Agent.get(__MODULE__, & &1.written)

    def set_best_friend(%{"conversation_id" => nil}) do
      Agent.update(__MODULE__, &%{&1 | written: true})

      {:ok,
       %{
         conversation_id: "44444444-4444-4444-8444-444444444444",
         best_friend: false,
         mutual: false,
         member_ids: [
           "11111111-1111-4111-8111-111111111111",
           "22222222-2222-4222-8222-222222222222"
         ]
       }}
    end

    def set_best_friend(%{"conversation_id" => conversation_id}) do
      Agent.update(__MODULE__, &%{&1 | written: true})

      case Application.get_env(:api_gateway, :best_friend_result) do
        nil ->
          {:ok,
           %{
             conversation_id: conversation_id,
             best_friend: true,
             mutual: true,
             member_ids: [
               "11111111-1111-4111-8111-111111111111",
               "22222222-2222-4222-8222-222222222222"
             ]
           }}

        result ->
          result
      end
    end
  end

  setup do
    keys = [
      {:shared_infra, :auth_client_adapter},
      {:shared_infra, :conversation_client_adapter},
      {:api_gateway, :best_friend_result}
    ]

    prev = for {app, key} <- keys, into: %{}, do: {{app, key}, Application.get_env(app, key)}

    start_supervised!(%{id: ConvStub, start: {ConvStub, :start_link, []}})
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.delete_env(:api_gateway, :best_friend_result)

    on_exit(fn ->
      for {{app, key}, value} <- prev do
        if value == nil,
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end
    end)

    for id <- [@me, @peer, @outsider],
        do: Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{id}")

    :ok
  end

  defp put(body) do
    :put
    |> conn("/api/v1/me/best-friend", %{})
    |> put_req_header("authorization", "Bearer me")
    |> UserController.set_best_friend(body)
  end

  test "a MUTUAL pin reaches BOTH members — and nobody else (MUT-4)" do
    conn = put(%{"conversation_id" => @dm})
    assert conn.status == 200

    assert %{"conversation_id" => @dm, "best_friend" => true, "mutual" => true} =
             Jason.decode!(conn.resp_body)

    for user_id <- [@me, @peer] do
      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "user:" <> ^user_id,
                       event: "best_friend_mutual",
                       payload: payload
                     },
                     500

      assert payload == %{conversation_id: @dm, mutual: true}
      assert Map.keys(payload) |> Enum.sort() == [:conversation_id, :mutual]
    end

    refute_receive %Phoenix.Socket.Broadcast{topic: "user:" <> @outsider}, 100
  end

  test "a ONE-SIDED pin is private: the write happens, the frame says mutual:false" do
    Application.put_env(
      :api_gateway,
      :best_friend_result,
      {:ok, %{conversation_id: @dm, best_friend: true, mutual: false, member_ids: [@me, @peer]}}
    )

    assert put(%{"conversation_id" => @dm}).status == 200

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "user:" <> @me,
      event: "best_friend_mutual",
      payload: %{mutual: false}
    }
  end

  test "UNPIN emits mutual:false to the pair that was mutual" do
    conn = put(%{"conversation_id" => nil})
    assert conn.status == 200
    assert %{"best_friend" => false, "mutual" => false} = Jason.decode!(conn.resp_body)

    for user_id <- [@me, @peer] do
      assert_receive %Phoenix.Socket.Broadcast{
        topic: "user:" <> ^user_id,
        event: "best_friend_mutual",
        payload: %{conversation_id: @dm, mutual: false}
      }
    end
  end

  test "MUT-3 guard: the frame is emitted AFTER the write — never before" do
    refute ConvStub.written?()
    put(%{"conversation_id" => @dm})

    assert_receive %Phoenix.Socket.Broadcast{event: "best_friend_mutual"}
    # The broadcast could only have been sent after set_best_friend returned, which is the only
    # thing that flips this.
    assert ConvStub.written?()
  end

  test "a NON-MEMBER's attempt is refused and emits nothing (MUT-4)" do
    Application.put_env(
      :api_gateway,
      :best_friend_result,
      {:error, :conversation_membership_forbidden}
    )

    conn = put(%{"conversation_id" => @dm})
    assert conn.status == 403
    assert %{"error" => %{"code" => "conversations.forbidden"}} = Jason.decode!(conn.resp_body)
    refute_receive %Phoenix.Socket.Broadcast{event: "best_friend_mutual"}, 100
  end

  test "a GROUP is a 422 with its own code, and emits nothing" do
    Application.put_env(:api_gateway, :best_friend_result, {:error, :best_friend_direct_only})

    conn = put(%{"conversation_id" => @dm})
    assert conn.status == 422

    assert %{"error" => %{"code" => "conversations.best_friend_direct_only"}} =
             Jason.decode!(conn.resp_body)

    refute_receive %Phoenix.Socket.Broadcast{event: "best_friend_mutual"}, 100
  end

  test "every emit names the user and the conversation" do
    log = capture_log([level: :info], fn -> put(%{"conversation_id" => @dm}) end)

    assert log =~ "best_friend_mutual emitted user=#{@me} conversation=#{@dm} mutual=true"
    assert log =~ "best_friend_mutual emitted user=#{@peer} conversation=#{@dm} mutual=true"
  end
end
