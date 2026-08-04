defmodule MessageService.ScyllaHttpBoundaryTest do
  @moduledoc """
  THE LAYER THE LADDER MISSED (`@tag :scylla_integration`). The production flip crashed on every chat
  open because `limit` arrived as the STRING "50" through POST /internal/messages/list — and every
  live test in C1–C8 called the adapter DIRECTLY with well-typed arguments. Fake-validated, one layer
  out: the engines were real, the CALLING CONVENTION was not.

  This suite goes through the REAL internal HTTP router (Plug.Parsers JSON, TokenPlug, the same
  `body(conn)` the gateway's HTTP client hits) with the Scylla-read adapter selected and EVERY
  numeric parameter deliberately sent as a JSON string — one test per store callback the HTTP surface
  can reach. If a param class regresses to raw arithmetic again, this suite crashes the way
  production did.
  """
  use ExUnit.Case, async: false

  alias MessageService.HTTP.Router
  alias MessageService.Repo
  alias SharedInfra.Scylla.XandraAdapter

  @moduletag :scylla_integration

  @cluster SharedInfra.Scylla.XandraAdapter.Cluster
  @gregorian_offset 0x01B21DD213814000
  @tenant_zero "00000000-0000-0000-0000-000000000001"
  @token "http-boundary-test-token"

  setup_all do
    nodes =
      System.get_env("SCYLLA_TEST_NODES", "localhost:9042") |> String.split(",", trim: true)

    ensure_no_cluster()
    {:ok, _pid} = XandraAdapter.start_link(nodes: nodes, keyspace: "chat_messages")
    Process.sleep(2_000)

    previous = %{
      client: Application.get_env(:message_service, :scylla_client_adapter),
      async: Application.get_env(:message_service, :scylla_shadow_async),
      adapter: Application.get_env(:message_service, :message_store_adapter),
      persistence: Application.get_env(:message_service, :message_persistence),
      token: Application.get_env(:shared_infra, :internal_api_token)
    }

    Application.put_env(:message_service, :scylla_client_adapter, XandraAdapter)
    Application.put_env(:message_service, :scylla_shadow_async, false)
    # THE FLIPPED CONFIGURATION — reads served from Scylla, exactly what production ran.
    Application.put_env(
      :message_service,
      :message_store_adapter,
      MessageService.MessageStore.ScyllaReadAdapter
    )

    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:shared_infra, :internal_api_token, @token)

    on_exit(fn ->
      restore = fn app, key, value ->
        if value, do: Application.put_env(app, key, value), else: Application.delete_env(app, key)
      end

      restore.(:message_service, :scylla_client_adapter, previous.client)
      restore.(:message_service, :scylla_shadow_async, previous.async)
      restore.(:message_service, :message_store_adapter, previous.adapter)
      restore.(:message_service, :message_persistence, previous.persistence)
      restore.(:shared_infra, :internal_api_token, previous.token)
      ensure_no_cluster()
    end)

    :ok
  end

  setup do
    case Repo.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    conversation = Ecto.UUID.generate()
    sender = Ecto.UUID.generate()
    reader = Ecto.UUID.generate()

    for u <- [sender, reader] do
      Repo.query!(
        "INSERT INTO users_auth (id, app_id, email, password_hash, created_at, updated_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', now(), now())",
        [u, @tenant_zero, "#{u}@test.local"]
      )
    end

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid, 'active', now(), now())",
      [conversation, @tenant_zero, sender]
    )

    for u <- [sender, reader] do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
        [conversation, u]
      )
    end

    {:ok, conversation: conversation, sender: sender, reader: reader}
  end

  defp ensure_no_cluster do
    case Process.whereis(@cluster) do
      nil -> :ok
      pid -> Supervisor.stop(pid, :normal, 5_000)
    end

    wait_unregistered(50)
  catch
    :exit, _ -> wait_unregistered(50)
  end

  defp wait_unregistered(0), do: :ok

  defp wait_unregistered(tries) do
    case Process.whereis(@cluster) do
      nil -> :ok
      _ -> Process.sleep(20) && wait_unregistered(tries - 1)
    end
  end

  # THE REAL PATH: JSON body through Plug.Parsers + TokenPlug + the route — what the gateway's HTTP
  # client actually produces, where every scalar is a string unless someone upstream parsed it.
  defp post!(path, body) do
    conn =
      Plug.Test.conn(:post, path, Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-internal-token", @token)
      |> Router.call(Router.init([]))

    assert conn.status == 200, "#{path} -> #{conn.status}: #{conn.resp_body}"
    Jason.decode!(conn.resp_body)
  end

  defp send_message!(conversation, sender, body_text) do
    %{"ok" => message} =
      post!("/internal/messages/create", %{
        "conversation_id" => conversation,
        "sender_user_id" => sender,
        "message_type" => "text",
        "body" => body_text
      })

    message
  end

  test "PUT + LIST — the exact production crash: list with limit as the STRING \"50\"",
       %{conversation: conversation, sender: sender} do
    message = send_message!(conversation, sender, "over http")

    # THE REPRO: this request, verbatim shape, crashed every chat open in production.
    %{"ok" => listing} =
      post!("/internal/messages/list", %{
        "conversation_id" => conversation,
        "limit" => "50"
      })

    assert Enum.any?(listing["messages"], &(&1["message_id"] == message["message_id"]))
  end

  test "UPDATE + DELETE over HTTP", %{conversation: conversation, sender: sender} do
    message = send_message!(conversation, sender, "original")

    %{"ok" => edited} =
      post!("/internal/messages/update", %{
        "conversation_id" => conversation,
        "message_id" => message["message_id"],
        "actor_user_id" => sender,
        "body" => "edited over http"
      })

    assert edited["body"] == "edited over http"

    %{"ok" => deleted} =
      post!("/internal/messages/delete", %{
        "conversation_id" => conversation,
        "message_id" => message["message_id"],
        "actor_user_id" => sender
      })

    assert deleted["status"] == "deleted"
  end

  test "RECEIPTS over HTTP: mark_delivered, mark_read, then message_info (reader lists intact)",
       %{conversation: conversation, sender: sender, reader: reader} do
    message = send_message!(conversation, sender, "receipt me")

    %{"ok" => _} =
      post!("/internal/receipts/mark_delivered", %{
        "conversation_id" => conversation,
        "message_id" => message["message_id"],
        "user_id" => reader
      })

    %{"ok" => _} =
      post!("/internal/receipts/mark_read", %{
        "conversation_id" => conversation,
        "message_id" => message["message_id"],
        "user_id" => reader
      })

    %{"ok" => info} =
      post!("/internal/receipts/info", %{
        "conversation_id" => conversation,
        "message_id" => message["message_id"],
        "viewer_user_id" => sender
      })

    assert Enum.map(info["read"], & &1["user_id"]) == [reader]
  end

  test "REACTIONS over HTTP: add then remove", %{conversation: conversation, sender: sender} do
    message = send_message!(conversation, sender, "react to me")

    %{"ok" => added} =
      post!("/internal/reactions/add", %{
        "conversation_id" => conversation,
        "message_id" => message["message_id"],
        "user_id" => sender,
        "emoji" => "❤️"
      })

    assert [%{"emoji" => "❤️", "count" => 1}] = added["reactions"]

    %{"ok" => removed} =
      post!("/internal/reactions/remove", %{
        "conversation_id" => conversation,
        "message_id" => message["message_id"],
        "user_id" => sender
      })

    assert removed["reactions"] == []
  end

  test "STARS over HTTP: add, list with page AND limit as strings, remove",
       %{conversation: conversation, sender: sender} do
    message = send_message!(conversation, sender, "star me")

    %{"ok" => _} =
      post!("/internal/stars/add", %{
        "conversation_id" => conversation,
        "message_id" => message["message_id"],
        "user_id" => sender
      })

    # page/limit as STRINGS — the same class as the production crash, on the stars path.
    %{"ok" => starred} =
      post!("/internal/stars/list", %{"user_id" => sender, "page" => "1", "limit" => "50"})

    assert Enum.map(starred["messages"], & &1["message_id"]) == [message["message_id"]]

    %{"ok" => _} =
      post!("/internal/stars/remove", %{
        "conversation_id" => conversation,
        "message_id" => message["message_id"],
        "user_id" => sender
      })
  end

  test "MEDIA over HTTP: list_media with string limit, by_media_id, download_allowed",
       %{conversation: conversation, sender: sender, reader: reader} do
    media_id = Ecto.UUID.generate()

    %{"ok" => _} =
      post!("/internal/messages/create", %{
        "conversation_id" => conversation,
        "sender_user_id" => sender,
        "message_type" => "media",
        "media_id" => media_id,
        "metadata" => %{"content_type" => "image/png", "media_id" => media_id}
      })

    %{"ok" => gallery} =
      post!("/internal/messages/list_media", %{
        "conversation_id" => conversation,
        "viewer_user_id" => reader,
        "limit" => "50"
      })

    assert [item] = gallery["items"]
    assert item["media_id"] == media_id

    %{"ok" => by_media} = post!("/internal/messages/by_media_id", %{"media_id" => media_id})
    assert by_media["conversation_id"] == conversation

    %{"ok" => oracle} =
      post!("/internal/media/download_allowed", %{
        "media_id" => media_id,
        "owner_user_id" => sender,
        "viewer_user_id" => reader
      })

    assert oracle["allowed"] == true
  end

  test "POLLS over HTTP: vote and votes through the flipped read path",
       %{conversation: conversation, sender: sender, reader: reader} do
    %{"ok" => poll_message} =
      post!("/internal/messages/create", %{
        "conversation_id" => conversation,
        "sender_user_id" => sender,
        "message_type" => "poll",
        "body" => "lunch?",
        "metadata" => %{
          "poll" => %{
            "question" => "lunch?",
            "allows_multiple" => false,
            "options" => [%{"id" => "o1", "text" => "pizza"}, %{"id" => "o2", "text" => "sushi"}]
          }
        }
      })

    %{"ok" => voted} =
      post!("/internal/polls/vote", %{
        "conversation_id" => conversation,
        "message_id" => poll_message["message_id"],
        "user_id" => reader,
        "option_ids" => ["o1"]
      })

    assert Enum.find(voted["poll"]["options"], &(&1["id"] == "o1"))["count"] == 1

    %{"ok" => votes} =
      post!("/internal/polls/votes", %{
        "conversation_id" => conversation,
        "message_id" => poll_message["message_id"]
      })

    assert Enum.find(votes["poll"]["options"], &(&1["id"] == "o1"))["count"] == 1
  end

  test "SEARCH over HTTP returns REAL results — never a silent empty list",
       %{conversation: conversation, sender: sender} do
    # WHAT THIS USED TO ASSERT, AND WHY IT CHANGED. It pinned the STUB:
    # `result["error"] =~ "unavailable"`. Commit 000ac22 pointed scylla_read's search at
    # PostgresAdapter, so the call now genuinely succeeds, `result["error"]` is nil, and
    # `nil =~ "unavailable"` raised FunctionClauseError — this suite has been red since. The
    # ASSERTION was wrong; the PROPERTY it protected is not, so the property moved rather than
    # disappeared (see the note below this test).
    #
    # Under scylla_read, reads come from Scylla but WRITES ARE STILL DUAL, so Postgres holds every
    # message and search is served from there. This seeds the row dual-write would have written.
    # Without it the search would legitimately match nothing, and asserting an empty list would
    # re-enshrine precisely the bug the original test existed to prevent.
    message_id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO messages " <>
        "(message_id, conversation_id, app_id, sender_user_id, message_type, body, status, created_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, $4::text::uuid, " <>
        "'text', 'a findable needle', 'active', now())",
      [message_id, conversation, @tenant_zero, sender]
    )

    # `page` as the STRING "1" — the calling convention this whole suite exists to hold.
    %{"ok" => search} =
      post!("/internal/search/messages", %{
        "user_id" => sender,
        "query" => "needle",
        "page" => "1"
      })

    # NOT an empty list. A search that silently returns nothing tells the user their query matched
    # nothing, which is a different and false statement from "search could not answer".
    assert search["messages"] != []
    assert Enum.any?(search["messages"], &(&1["message_id"] == message_id))
  end

  # WHERE THE DEGRADATION PROPERTY LIVES NOW: a store answering `:message_store_unavailable` must
  # surface as 503 `search.unavailable` and NEVER as a 200 with an empty list. That is asserted at the
  # gateway by ApiGatewayWeb.StoreUnavailableMappingTest — "SEARCH: a store that cannot answer is 503
  # search.unavailable — never 400, never empty" — which runs in the DEFAULT suite and needs no
  # Scylla. That is a strictly better home than a Scylla-gated boundary test: the property holds
  # whichever store is selected, so the test that guards it should not require one.
end
