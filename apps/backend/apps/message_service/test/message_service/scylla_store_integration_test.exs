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

    # CQL timestamp is millisecond precision; assert to the second, as ISO strings (the wire shape).
    assert is_binary(got.created_at)

    assert String.starts_with?(
             got.created_at,
             now |> DateTime.truncate(:second) |> DateTime.to_iso8601() |> String.slice(0, 19)
           )

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
    assert is_binary(got.edited_at)

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
    assert is_binary(got.deleted_at)

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

  test "the STUB rows of the moduledoc table are really stubs — no third category" do
    for fun <- [
          :upsert_reaction,
          :remove_reaction,
          :star_message,
          :unstar_message,
          :list_starred,
          :search_messages
        ] do
      assert apply(ScyllaAdapter, fun, [%{}]) == {:error, :message_store_unavailable},
             "#{fun} must be an explicit stub"
    end
  end

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
end
