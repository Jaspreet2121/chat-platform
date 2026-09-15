defmodule ApiGatewayWeb.StatusUpdatedTest do
  @moduledoc """
  `status_updated` on a status post/delete — the live replacement for "refresh the tab to see a
  contact's new status".

  Pinned: the event {user_id, status_id, action} reaches every user in the post's AUDIENCE (the
  message service's predicate, never peers_of), never the actor, never anyone outside the
  audience, and only AFTER the store has committed — the audience lookup runs during emission, so
  what the store holds at that moment is what the event was emitted against. Every outcome logs.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.StatusController

  @actor "11111111-1111-4111-8111-111111111111"
  @peer "22222222-2222-4222-8222-222222222222"
  @stranger "33333333-3333-4333-8333-333333333333"
  @status "aaaaaaaa-0000-4000-8000-0000000000aa"

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer actor"}),
      do: {:ok, %{user_id: "11111111-1111-4111-8111-111111111111", app_id: "app1"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  # The store: commits are recorded, and the audience lookup reports what was committed at the
  # moment it ran (the after-commit proof). The audience itself is configurable per test.
  defmodule MsgStub do
    @moduledoc false
    def start_link,
      do: Agent.start_link(fn -> %{posted: false, deleted: false} end, name: __MODULE__)

    def committed, do: Agent.get(__MODULE__, & &1)

    def post_status(attrs) do
      Agent.update(__MODULE__, &%{&1 | posted: true})

      {:ok,
       %{
         status_id: "aaaaaaaa-0000-4000-8000-0000000000aa",
         owner_user_id: attrs["owner_user_id"],
         kind: attrs["kind"],
         body: attrs["body"],
         media_id: nil,
         metadata: %{},
         created_at: "t1",
         expires_at: "t2"
       }}
    end

    def delete_status(%{"status_id" => "aaaaaaaa-0000-4000-8000-0000000000aa"}) do
      Agent.update(__MODULE__, &%{&1 | deleted: true})
      {:ok, %{deleted: true}}
    end

    def delete_status(_attrs), do: {:error, :status_not_found}

    def status_audience(%{"owner_user_id" => owner, "status_id" => status_id}) do
      send(
        Application.get_env(:api_gateway, :status_updated_test_pid),
        {:audience_called, owner, status_id, committed()}
      )

      case Application.get_env(:api_gateway, :status_audience_result) do
        nil -> {:ok, %{user_ids: ["22222222-2222-4222-8222-222222222222"]}}
        result -> result
      end
    end
  end

  setup do
    keys = [
      {:shared_infra, :auth_client_adapter},
      {:shared_infra, :message_client_adapter},
      {:api_gateway, :status_updated_test_pid},
      {:api_gateway, :status_audience_result},
      {:message_service, :message_persistence}
    ]

    prev = for {app, key} <- keys, into: %{}, do: {{app, key}, Application.get_env(app, key)}

    start_supervised!(%{id: MsgStub, start: {MsgStub, :start_link, []}})
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)
    Application.put_env(:api_gateway, :status_updated_test_pid, self())
    Application.delete_env(:api_gateway, :status_audience_result)
    Application.put_env(:message_service, :message_persistence, true)

    on_exit(fn ->
      for {{app, key}, value} <- prev do
        if value == nil,
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end
    end)

    for id <- [@peer, @actor, @stranger],
        do: Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{id}")

    :ok
  end

  defp authed(method) do
    method
    |> conn("/api/v1/status", %{})
    |> put_req_header("authorization", "Bearer actor")
  end

  defp post_text, do: StatusController.create(authed(:post), %{"kind" => "text", "body" => "hi"})
  defp delete_it, do: StatusController.delete(authed(:delete), %{"status_id" => @status})

  test "POSTED reaches the audience member, key-set pinned; stranger and actor stay silent" do
    assert post_text().status == 201

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "user:" <> @peer,
      event: "status_updated",
      payload: payload
    }

    assert payload == %{user_id: @actor, status_id: @status, action: "posted"}
    assert Map.keys(payload) |> Enum.sort() == [:action, :status_id, :user_id]
    refute_receive %Phoenix.Socket.Broadcast{topic: "user:" <> @stranger}, 100
    refute_receive %Phoenix.Socket.Broadcast{topic: "user:" <> @actor}, 100
  end

  test "DELETED reaches the audience member with action deleted; never the actor" do
    assert delete_it().status == 200

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "user:" <> @peer,
      event: "status_updated",
      payload: %{user_id: @actor, status_id: @status, action: "deleted"}
    }

    refute_receive %Phoenix.Socket.Broadcast{topic: "user:" <> @actor}, 100
  end

  test "MUT-1 guard: emitted AFTER the commit — the store already holds the row / the tombstone when the fan-out runs" do
    post_text()
    assert_receive {:audience_called, @actor, @status, %{posted: true}}

    delete_it()
    assert_receive {:audience_called, @actor, @status, %{deleted: true}}
  end

  test "the recipient set is the AUDIENCE the message service answers — not peers_of — so a user it omits gets nothing" do
    Application.put_env(:api_gateway, :status_audience_result, {:ok, %{user_ids: [@peer]}})
    post_text()
    assert_receive %Phoenix.Socket.Broadcast{topic: "user:" <> @peer}
    refute_receive %Phoenix.Socket.Broadcast{topic: "user:" <> @stranger}, 100
  end

  test "MUT-3 guard: an audience reply that names the actor still never reaches the actor" do
    Application.put_env(
      :api_gateway,
      :status_audience_result,
      {:ok, %{user_ids: [@actor, @peer]}}
    )

    post_text()
    assert_receive %Phoenix.Socket.Broadcast{topic: "user:" <> @peer}
    refute_receive %Phoenix.Socket.Broadcast{topic: "user:" <> @actor}, 100
  end

  describe "every outcome logs" do
    test "EMITTED: names the actor, the status, how many and the action (MUT-4 guard)" do
      log = capture_log([level: :info], fn -> post_text() end)

      assert log =~
               "status_updated emitted user=#{@actor} status=#{@status} recipients=1 action=posted"

      log = capture_log([level: :info], fn -> delete_it() end)

      assert log =~
               "status_updated emitted user=#{@actor} status=#{@status} recipients=1 action=deleted"
    end

    test "NO_AUDIENCE: an empty set says so, at info — not silence; nothing is broadcast" do
      Application.put_env(:api_gateway, :status_audience_result, {:ok, %{user_ids: []}})
      log = capture_log([level: :info], fn -> assert post_text().status == 201 end)
      assert log =~ "status_updated skipped user=#{@actor} status=#{@status} reason=no_audience"
      refute_receive %Phoenix.Socket.Broadcast{}, 100
    end

    test "NO_AUDIENCE also when the only name answered is the actor" do
      Application.put_env(:api_gateway, :status_audience_result, {:ok, %{user_ids: [@actor]}})
      log = capture_log([level: :info], fn -> post_text() end)
      assert log =~ "reason=no_audience"
      refute_receive %Phoenix.Socket.Broadcast{}, 100
    end

    test "FAILED: a lookup error is a WARNING with the reason and never fails the request" do
      Application.put_env(:api_gateway, :status_audience_result, {:error, :message_unavailable})
      log = capture_log([level: :warning], fn -> assert post_text().status == 201 end)

      assert log =~
               "status_updated failed user=#{@actor} status=#{@status} action=posted: :message_unavailable"

      refute_receive %Phoenix.Socket.Broadcast{}, 100
    end

    test "FAILED: a malformed reply (no user_ids list) is an error, not an empty audience" do
      Application.put_env(:api_gateway, :status_audience_result, {:ok, %{nope: true}})
      log = capture_log([level: :warning], fn -> post_text() end)
      assert log =~ "status_updated failed"
      assert log =~ "malformed_reply"
    end
  end
end
