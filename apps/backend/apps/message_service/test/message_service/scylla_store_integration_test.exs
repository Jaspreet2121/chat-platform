defmodule MessageService.ScyllaStoreIntegrationTest do
  @moduledoc """
  THE FIRST TESTS EVER TO RUN THIS ADAPTER AGAINST A REAL SCYLLA (`@tag :scylla_integration`,
  scripts/test-scylla.sh). Everything here previously "passed" only against a fake client while the
  wire types were guaranteed to fail on a real engine — the $N::uuid failure shape.

  Proves, on a live keyspace: the Phase-D encodings (uuid strings, %Date{} buckets, %DateTime{}
  timestamps, the metadata-JSON convention round-tripping a NESTED poll definition); get_message as a
  bucket-derived POINT READ including the midnight race; list_messages' real cursor pagination across
  bucket boundaries with cross-partition time ordering; update/delete resolving the row's true bucket;
  and receipts landing readably. Every VERIFIED row of the ScyllaAdapter moduledoc table is proven
  here; the STUB rows are asserted to be stubs.
  """
  use ExUnit.Case, async: false

  alias MessageService.MessageStore.ScyllaAdapter
  alias MessageService.Persistence.MessageReceipts
  alias MessageService.Persistence.ScyllaCodec
  alias SharedInfra.Scylla.XandraAdapter

  @moduletag :scylla_integration

  @cluster SharedInfra.Scylla.XandraAdapter.Cluster
  @gregorian_offset 0x01B21DD213814000

  setup_all do
    nodes =
      System.get_env("SCYLLA_TEST_NODES", "localhost:9042") |> String.split(",", trim: true)

    ensure_no_cluster()
    {:ok, _pid} = XandraAdapter.start_link(nodes: nodes, keyspace: "chat_messages")
    # sync_connect is deliberately off (boot safety) — give the background connect a moment.
    Process.sleep(2_000)

    previous = Application.get_env(:message_service, :scylla_client_adapter)
    Application.put_env(:message_service, :scylla_client_adapter, XandraAdapter)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:message_service, :scylla_client_adapter, previous),
        else: Application.delete_env(:message_service, :scylla_client_adapter)

      ensure_no_cluster()
    end)

    :ok
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

  # A v1 timeuuid embedding a CHOSEN instant — same layout as Messages.generate_timeuuid/0, so the
  # bucket-derivation under test sees exactly what production ids look like.
  defp timeuuid_at(%DateTime{} = dt) do
    timestamp = DateTime.to_unix(dt, :microsecond) * 10 + @gregorian_offset

    time_low = Bitwise.band(timestamp, 0xFFFF_FFFF)
    time_mid = timestamp |> Bitwise.bsr(32) |> Bitwise.band(0xFFFF)
    time_hi = timestamp |> Bitwise.bsr(48) |> Bitwise.band(0x0FFF) |> Bitwise.bor(0x1000)

    <<clock_seq::16, node::48>> = :crypto.strong_rand_bytes(8)
    clock_seq = clock_seq |> Bitwise.band(0x3FFF) |> Bitwise.bor(0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [
      time_low,
      time_mid,
      time_hi,
      clock_seq,
      node
    ])
    |> IO.iodata_to_binary()
  end

  defp put!(conversation_id, %DateTime{} = at, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          "conversation_id" => conversation_id,
          "bucket_date" => at |> DateTime.to_date() |> Date.to_iso8601(),
          "message_id" => timeuuid_at(at),
          "sender_user_id" => Ecto.UUID.generate(),
          "message_type" => "text",
          "body" => "hello scylla",
          "media_id" => nil,
          "reply_to_message_id" => nil,
          "status" => "active",
          "metadata" => %{},
          "created_at" => at,
          "edited_at" => nil,
          "deleted_at" => nil
        },
        overrides
      )

    {:ok, response} = ScyllaAdapter.put_message(attrs)
    {attrs["message_id"], response}
  end

  test "PHASE D IS REAL: a message with a NESTED poll definition round-trips put -> point-read get" do
    conversation_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    poll = %{
      "question" => "lunch?",
      "allows_multiple" => false,
      "options" => [
        %{"id" => "o1", "text" => "pizza"},
        %{"id" => "o2", "text" => "sushi"}
      ]
    }

    {message_id, _put_response} =
      put!(conversation_id, now, %{
        "message_type" => "poll",
        "body" => "lunch?",
        "metadata" => %{"poll" => poll, "count" => 2, "flagged" => false}
      })

    assert {:ok, got} =
             ScyllaAdapter.get_message(%{
               "conversation_id" => conversation_id,
               "message_id" => message_id
             })

    # The metadata-JSON convention round-trips the NESTED structure intact — map<text,text> did not
    # flatten, stringify, or lose it. This is the read the poll port's fetch_poll will depend on.
    assert got.metadata["poll"] == poll
    assert got.metadata["count"] == 2
    assert got.metadata["flagged"] == false

    assert got.message_id == message_id
    assert got.status == "active"

    # THE CONTRACT: the same type PostgresAdapter returns — %DateTime{}, not an ISO string.
    # This assertion used to read `assert is_binary(got.created_at)`, pinning the bug: a live-engine
    # test can still encode a wrong belief, and this one did, which is why the inbox projection could
    # not apply a single event while every suite was green.
    assert %DateTime{} = got.created_at

    # CQL timestamp is millisecond precision, so compare to the second.
    assert DateTime.truncate(got.created_at, :second) == DateTime.truncate(now, :second)

    assert got.edited_at == nil
    assert got.deleted_at == nil
  end

  test "get_message survives the MIDNIGHT RACE: bucket = created_at's day, timeuuid lands on the next" do
    conversation_id = Ecto.UUID.generate()

    # A row whose stored bucket is YESTERDAY (created_at side of midnight) while its timeuuid embeds
    # 00:00:00.050 TODAY — the derived candidate misses, the previous-day candidate must hit.
    today_midnight =
      DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00.050], "Etc/UTC")

    yesterday = today_midnight |> DateTime.to_date() |> Date.add(-1) |> Date.to_iso8601()

    {message_id, _} =
      put!(conversation_id, today_midnight, %{
        "bucket_date" => yesterday,
        "created_at" => DateTime.add(today_midnight, -100, :millisecond)
      })

    assert {:ok, got} =
             ScyllaAdapter.get_message(%{
               "conversation_id" => conversation_id,
               "message_id" => message_id
             })

    assert got.message_id == message_id
  end

  test "an unknown message is :message_not_found, not a scan and not a crash" do
    assert {:error, :message_not_found} =
             ScyllaAdapter.get_message(%{
               "conversation_id" => Ecto.UUID.generate(),
               "message_id" => timeuuid_at(DateTime.utc_now())
             })

    # A malformed id (not a v1 timeuuid) has no derivable bucket — same answer, no exception.
    assert {:error, :message_not_found} =
             ScyllaAdapter.get_message(%{
               "conversation_id" => Ecto.UUID.generate(),
               "message_id" => "not-a-timeuuid"
             })
  end

  test "REAL PAGINATION: cursor pages walk bucket boundaries in time order (next_cursor was a lie before)" do
    conversation_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    # 7 messages across three daily buckets: 3 days ago x3, yesterday x2, today x2.
    ids =
      for {days_ago, index} <- [{3, 1}, {3, 2}, {3, 3}, {1, 4}, {1, 5}, {0, 6}, {0, 7}] do
        at = now |> DateTime.add(-days_ago * 86_400, :second) |> DateTime.add(index, :second)
        {id, _} = put!(conversation_id, at, %{"body" => "m#{index}"})
        id
      end

    newest_first = Enum.reverse(ids)

    assert {:ok, page1} =
             ScyllaAdapter.list_messages(%{"conversation_id" => conversation_id, "limit" => 3})

    assert Enum.map(page1.messages, & &1.message_id) == Enum.take(newest_first, 3)
    assert is_binary(page1.next_cursor)

    assert {:ok, page2} =
             ScyllaAdapter.list_messages(%{
               "conversation_id" => conversation_id,
               "limit" => 3,
               "cursor" => page1.next_cursor
             })

    # Page 2 crosses from today's bucket back into the 3-days-ago bucket — the walk, not one partition.
    assert Enum.map(page2.messages, & &1.message_id) ==
             newest_first |> Enum.drop(3) |> Enum.take(3)

    assert {:ok, page3} =
             ScyllaAdapter.list_messages(%{
               "conversation_id" => conversation_id,
               "limit" => 3,
               "cursor" => page2.next_cursor
             })

    assert Enum.map(page3.messages, & &1.message_id) == Enum.drop(newest_first, 6)
  end

  test "update and delete resolve the row's TRUE bucket, then mutate it visibly" do
    conversation_id = Ecto.UUID.generate()
    {message_id, _} = put!(conversation_id, DateTime.utc_now(), %{"body" => "original"})

    assert {:ok, edited} =
             ScyllaAdapter.update_message(%{
               "conversation_id" => conversation_id,
               "message_id" => message_id,
               "body" => "edited body"
             })

    assert edited.status == "edited"

    assert {:ok, got} =
             ScyllaAdapter.get_message(%{
               "conversation_id" => conversation_id,
               "message_id" => message_id
             })

    assert got.body == "edited body"
    assert got.status == "edited"
    # Same contract as created_at: %DateTime{}, matching PostgresAdapter. Was is_binary/1.
    assert %DateTime{} = got.edited_at

    assert {:ok, deleted} =
             ScyllaAdapter.delete_message(%{
               "conversation_id" => conversation_id,
               "message_id" => message_id
             })

    assert deleted.status == "deleted"

    assert {:ok, got} =
             ScyllaAdapter.get_message(%{
               "conversation_id" => conversation_id,
               "message_id" => message_id
             })

    assert got.status == "deleted"
    # Same contract as created_at: %DateTime{}, matching PostgresAdapter. Was is_binary/1.
    assert %DateTime{} = got.deleted_at

    # Mutating a message that does not exist is :message_not_found — resolution is the gate.
    assert {:error, :message_not_found} =
             ScyllaAdapter.update_message(%{
               "conversation_id" => conversation_id,
               "message_id" => timeuuid_at(DateTime.utc_now()),
               "body" => "ghost"
             })
  end

  test "receipts LAND and are READABLE: delivered then read for the same user upserts, not duplicates" do
    conversation_id = Ecto.UUID.generate()
    {message_id, _} = put!(conversation_id, DateTime.utc_now())
    reader = Ecto.UUID.generate()

    assert {:ok, _} =
             ScyllaAdapter.mark_delivered(%{
               "conversation_id" => conversation_id,
               "message_id" => message_id,
               "user_id" => reader
             })

    assert {:ok, _} =
             ScyllaAdapter.mark_read(%{
               "conversation_id" => conversation_id,
               "message_id" => message_id,
               "user_id" => reader
             })

    plan =
      MessageReceipts.list_for_message_plan(%{
        "conversation_id" => conversation_id,
        "message_id" => message_id
      })

    assert {:ok, %{rows: rows}} = XandraAdapter.execute(plan.statement, plan.params, [])

    # (conversation, message, user) is the primary key — the second write UPSERTED, so one row, read.
    assert [row] = rows
    assert row["user_id"] == reader
    assert row["status"] == "read"
  end

  # HISTORY NOTE, replacing the test that stood here: "search is the ONLY remaining stub" asserted
  # search_messages returned :message_store_unavailable — a DELIBERATE stub from 2026-08-01, pinned
  # so nobody could un-stub it casually. DECISION_LOG [2026-08-08] retired it on the record (message
  # text lives in Postgres as a search-only copy), so what that test proved is deliberately no
  # longer true. Its replacement is the index+hydration test at the end of this file, which proves
  # the behaviour that superseded the stub rather than re-pinning either.

  test "codec self-check: bucket_candidates inverts the generator for arbitrary instants" do
    for iso <- [
          "2026-01-01 00:00:00.001Z",
          "2026-06-15 12:30:45.500Z",
          "2026-12-31 23:59:59.999Z"
        ] do
      {:ok, dt, _} = DateTime.from_iso8601(iso)
      id = timeuuid_at(dt)

      assert {:ok, decoded} = ScyllaCodec.timeuuid_to_datetime(id)
      assert DateTime.diff(decoded, dt, :millisecond) == 0

      assert ScyllaCodec.bucket_candidates(id) == [
               DateTime.to_date(dt),
               Date.add(DateTime.to_date(dt), -1)
             ]
    end
  end

  test "REACTIONS: the CQL partition verified live — PK replace, aggregate ordering, removal" do
    conversation_id = Ecto.UUID.generate()
    {message_id, _} = put!(conversation_id, DateTime.utc_now())
    [u1, u2, u3] = for _ <- 1..3, do: Ecto.UUID.generate()

    react = fn user, emoji ->
      {:ok, response} =
        ScyllaAdapter.upsert_reaction(%{
          "conversation_id" => conversation_id,
          "message_id" => message_id,
          "user_id" => user,
          "emoji" => emoji
        })

      response
    end

    react.(u1, "❤️")
    react.(u2, "❤️")
    response = react.(u3, "👍")

    # Aggregate ordering: count desc, then emoji — the Postgres adapter's exact contract.
    assert response.reactions == [%{emoji: "❤️", count: 2}, %{emoji: "👍", count: 1}]

    # THE SHAPE CHECK the schema file can't give us: an INSERT for the same (partition, user) must
    # REPLACE (one emoji per user per message — Postgres ON CONFLICT semantics). If the primary key
    # were declared differently than the .cql claims, this would grow to 2 rows and count ❤️+😀.
    response = react.(u1, "😀")

    assert response.reactions == [
             %{emoji: "❤️", count: 1},
             %{emoji: "👍", count: 1},
             %{emoji: "😀", count: 1}
           ]

    # And the raw partition really holds ONE row for u1 with the REPLACED value in the `reaction`
    # column (domain "emoji" is mapped at the adapter boundary, nowhere else).
    plan =
      MessageService.Persistence.MessageReactions.list_for_message_plan(%{
        "conversation_id" => conversation_id,
        "message_id" => message_id
      })

    {:ok, %{rows: raw}} = XandraAdapter.execute(plan.statement, plan.params, [])
    u1_rows = Enum.filter(raw, &(&1["user_id"] == u1))
    assert [%{"reaction" => "😀"}] = u1_rows

    # Removal drops the user's reaction from the aggregate.
    {:ok, response} =
      ScyllaAdapter.remove_reaction(%{
        "conversation_id" => conversation_id,
        "message_id" => message_id,
        "user_id" => u2
      })

    assert response.reactions == [%{emoji: "👍", count: 1}, %{emoji: "😀", count: 1}]
  end

  test "STARS: Postgres ids hydrated by bounded-concurrency point reads; drift drops, never crashes" do
    # The satellite lives in Postgres — one of two scylla-gate tests that need the SQL repo too
    # (the other is the unread-decrement wiring proof at the end of this file).
    case MessageService.Repo.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MessageService.Repo)

    conversation_id = Ecto.UUID.generate()
    user = Ecto.UUID.generate()
    now = DateTime.utc_now()

    # Three real messages in Scylla, starred in reverse order (list is starred-at DESC).
    ids =
      for i <- 1..3 do
        {id, _} = put!(conversation_id, DateTime.add(now, -i * 60, :second), %{"body" => "m#{i}"})

        {:ok, %{is_starred: true}} =
          ScyllaAdapter.star_message(%{
            "conversation_id" => conversation_id,
            "message_id" => id,
            "user_id" => user
          })

        # Distinct starred_at so the order is deterministic.
        MessageService.Repo.query!(
          "UPDATE starred_messages SET created_at = now() - make_interval(secs => $3) " <>
            "WHERE user_id = $1::text::uuid AND message_id = $2::text::uuid",
          [user, id, (4 - i) * 60]
        )

        id
      end

    # A DRIFTED star: the id exists in Postgres but no Scylla row does.
    {:ok, _} =
      ScyllaAdapter.star_message(%{
        "conversation_id" => conversation_id,
        "message_id" => timeuuid_at(now),
        "user_id" => user
      })

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, %{messages: messages}} = ScyllaAdapter.list_starred(%{"user_id" => user})

        # The drifted id is DROPPED (shorter page), the three real ones hydrate, starred-at DESC =
        # star order m3, m2, m1 — and every row carries is_starred.
        assert Enum.map(messages, & &1.body) == ["m3", "m2", "m1"]
        assert Enum.all?(messages, & &1.is_starred)
        send(self(), :asserted)
      end)

    assert_received :asserted
    assert log =~ "projection drift"

    # Unstar removes from the page.
    {:ok, %{is_starred: false}} =
      ScyllaAdapter.unstar_message(%{
        "conversation_id" => conversation_id,
        "message_id" => hd(ids),
        "user_id" => user
      })

    {:ok, %{messages: messages}} = ScyllaAdapter.list_starred(%{"user_id" => user})
    refute Enum.any?(messages, &(&1.message_id == hd(ids)))
  end

  # --- THE UNREAD DECREMENT, END TO END THROUGH THE REAL ADAPTER -----------------------------------
  #
  # MessageService.InboxProjectionTest proves record_read_once/4 itself. This proves it is WIRED:
  # that ScyllaAdapter.mark_read actually reaches it against a live keyspace. Before this, every
  # in-transaction maintenance call lived in PostgresAdapter and this adapter called InboxProjection
  # nowhere at all, so unread_count only ever increased. An unwired decrement would pass every unit
  # test in the other file and change nothing in production.

  test "mark_read DECREMENTS unread in Postgres — the adapter is wired, not just the function" do
    # Same repo+sandbox pattern as the STARS test above; the sandbox transaction rolls the Postgres
    # rows back, so nothing needs cleaning up by hand.
    case MessageService.Repo.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MessageService.Repo)

    tenant = "00000000-0000-0000-0000-000000000001"
    conversation_id = Ecto.UUID.generate()
    sender = Ecto.UUID.generate()
    reader = Ecto.UUID.generate()

    for u <- [sender, reader] do
      MessageService.Repo.query!(
        "INSERT INTO users_auth (id, app_id, phone_number, status) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active')",
        [u, tenant, "+1555#{System.unique_integer([:positive])}"]
      )
    end

    MessageService.Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid)",
      [conversation_id, tenant, sender]
    )

    for u <- [sender, reader] do
      MessageService.Repo.query!(
        "INSERT INTO conversation_participants " <>
          "(conversation_id, user_id, role, joined_at, unread_count) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now(), $3)",
        [conversation_id, u, if(u == reader, do: 2, else: 0)]
      )
    end

    # A REAL Scylla row — the decrement needs its sender_user_id, deleted_at and created_at, which the
    # mark_read attrs do not carry, so the adapter point-reads it.
    {message_id, _} = put!(conversation_id, DateTime.utc_now(), %{"sender_user_id" => sender})

    unread = fn user ->
      %{rows: [[n]]} =
        MessageService.Repo.query!(
          "SELECT unread_count FROM conversation_participants " <>
            "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
          [conversation_id, user]
        )

      n
    end

    attrs = %{
      "conversation_id" => conversation_id,
      "message_id" => message_id,
      "user_id" => reader
    }

    assert {:ok, _} = ScyllaAdapter.mark_read(attrs)
    assert unread.(reader) == 1

    # Idempotent through the real adapter too, not only through the projection function.
    assert {:ok, _} = ScyllaAdapter.mark_read(attrs)
    assert unread.(reader) == 1

    # The SENDER marking their own message read must not touch their counter.
    assert {:ok, _} = ScyllaAdapter.mark_read(%{attrs | "user_id" => sender})
    assert unread.(sender) == 0
  end

  # --- SEARCH OVER THE INDEX, END TO END THROUGH THE REAL ADAPTER ----------------------------------
  #
  # SearchIndexTest proves the projection; this proves the ADAPTER's query + hydration against a
  # live keyspace: real Scylla rows, real index rows, the real VisibilityWindow masking SQL, and the
  # drift-drop that guarantees deleted content never renders even when the index row survives.

  test "search: index filter -> Scylla hydration; masking applies; a stale index row NEVER renders" do
    # Flag OFF -> still the honest 503, never a silent empty list (the message-service.md contract).
    # The index is served only while its maintainer runs.
    prev_flag = Application.get_env(:message_service, :kafka_search_consumer_enabled)

    assert ScyllaAdapter.search_messages(%{"user_id" => Ecto.UUID.generate(), "query" => "x"}) ==
             {:error, :message_store_unavailable}

    Application.put_env(:message_service, :kafka_search_consumer_enabled, true)

    on_exit(fn ->
      if prev_flag,
        do: Application.put_env(:message_service, :kafka_search_consumer_enabled, prev_flag),
        else: Application.delete_env(:message_service, :kafka_search_consumer_enabled)
    end)

    case MessageService.Repo.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MessageService.Repo)

    tenant = "00000000-0000-0000-0000-000000000001"
    conversation_id = Ecto.UUID.generate()
    searcher = Ecto.UUID.generate()
    outsider = Ecto.UUID.generate()
    sender = Ecto.UUID.generate()
    now = DateTime.utc_now()

    for u <- [searcher, outsider, sender] do
      MessageService.Repo.query!(
        "INSERT INTO users_auth (id, app_id, phone_number, status) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active')",
        [u, tenant, "+1555#{System.unique_integer([:positive])}"]
      )
    end

    MessageService.Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid)",
      [conversation_id, tenant, sender]
    )

    # searcher + sender are members; outsider is NOT — the oracle case.
    for u <- [searcher, sender] do
      MessageService.Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
        [conversation_id, u]
      )
    end

    # Two REAL Scylla rows...
    {hit_id, _} =
      put!(conversation_id, DateTime.add(now, -60, :second), %{
        "sender_user_id" => sender,
        "body" => "the searchable needle body"
      })

    {other_id, _} =
      put!(conversation_id, DateTime.add(now, -120, :second), %{
        "sender_user_id" => sender,
        "body" => "nothing relevant here"
      })

    # ...indexed the way the consumer would index them.
    index = fn id, at, text ->
      MessageService.Repo.query!(
        "INSERT INTO message_search (message_id, conversation_id, sender_user_id, created_at, search_text) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, $4, $5)",
        [id, conversation_id, sender, at, text]
      )
    end

    index.(hit_id, DateTime.add(now, -60, :second), "the searchable needle body")
    index.(other_id, DateTime.add(now, -120, :second), "nothing relevant here")

    # A STALE index row: indexed text but NO Scylla row (the missed-delete shape). It matches the
    # query; hydration must drop it, because the store is the only truth about existence.
    stale_id = timeuuid_at(DateTime.add(now, -30, :second))
    index.(stale_id, DateTime.add(now, -30, :second), "needle in a deleted message")

    search = fn user ->
      {:ok, %{messages: messages}} =
        ScyllaAdapter.search_messages(%{"user_id" => user, "query" => "needle", "page" => 1})

      Enum.map(messages, & &1.message_id)
    end

    # The member finds exactly the live hit: substring match, the non-matching row excluded, the
    # stale row DROPPED BY HYDRATION not by luck.
    assert search.(searcher) == [hit_id]

    # THE ORACLE CASE: a non-member finds nothing, structurally (join predicate, not post-filter).
    assert search.(outsider) == []

    # cleared_before masks at QUERY time: clear history after the messages -> nothing findable,
    # index rows untouched.
    MessageService.Repo.query!(
      "UPDATE conversation_participants SET cleared_before = now() " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conversation_id, searcher]
    )

    assert search.(searcher) == []
  end
end
