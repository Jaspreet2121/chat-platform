defmodule MessageService.ScyllaSchemaShapeTest do
  @moduledoc """
  LIVE KEY-SHAPE assertions for the C3 media projections (`@tag :scylla_integration`).

  The byte-identity drift test (ScyllaSchemaDriftTest) proves the two canonical FILES match each
  other. It cannot prove the DEPLOYED tables match the files — and both real Scylla bugs on this
  ladder (C1's token-order truncation, C2's PK-replacement check) were engine-behaviour facts no file
  comparison could catch. This suite exercises each table's INTENDED ACCESS PATTERN through the raw
  client (deliberately not through adapter code — nothing in production reads these tables until C4)
  and fails if the deployed partition/clustering shape drifts from what the C4 queries will assume.

  What each test PROVES vs ASSUMES is stated on the test itself.
  """
  use ExUnit.Case, async: false

  alias SharedInfra.Scylla.XandraAdapter

  @moduletag :scylla_integration

  @cluster SharedInfra.Scylla.XandraAdapter.Cluster

  setup_all do
    nodes =
      System.get_env("SCYLLA_TEST_NODES", "localhost:9042") |> String.split(",", trim: true)

    ensure_no_cluster()
    {:ok, _pid} = XandraAdapter.start_link(nodes: nodes, keyspace: "chat_messages")
    Process.sleep(2_000)

    on_exit(&ensure_no_cluster/0)
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

  defp execute!(statement, params) do
    {:ok, result} = XandraAdapter.execute(statement, params, [])
    result
  end

  defp timeuuid_at(%DateTime{} = dt) do
    gregorian_offset = 0x01B21DD213814000
    timestamp = DateTime.to_unix(dt, :microsecond) * 10 + gregorian_offset

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

  # PROVES: the partition key is media_id ALONE (a WHERE media_id = ? with no created_at would ERROR
  # with "partition key incompletely restricted" if created_at were part of it), clustering is
  # created_at ASC (LIMIT 1 returns the EARLIEST reference regardless of insertion order — exactly
  # get_by_media_id's "first message carrying it" semantics), and sender_user_id rides each row (what
  # the download oracle filters on without a second read).
  # ASSUMES: column types beyond the ones written here (exercised implicitly by the round-trip).
  test "messages_by_media: one partition per media, earliest-first clustering, sender carried" do
    media_id = Ecto.UUID.generate()
    now = DateTime.utc_now()
    owner = Ecto.UUID.generate()
    other = Ecto.UUID.generate()

    insert = fn seconds_ago, conversation_id, sender ->
      execute!(
        "INSERT INTO messages_by_media (media_id, created_at, message_id, conversation_id, sender_user_id) " <>
          "VALUES (?, ?, ?, ?, ?)",
        [
          media_id,
          DateTime.add(now, -seconds_ago, :second),
          timeuuid_at(DateTime.add(now, -seconds_ago, :second)),
          conversation_id,
          sender
        ]
      )
    end

    # Inserted OUT of chronological order — clustering must order them, not insertion.
    [conv_late, conv_earliest, conv_mid] = for _ <- 1..3, do: Ecto.UUID.generate()
    insert.(60, conv_late, owner)
    insert.(300, conv_earliest, owner)
    insert.(120, conv_mid, other)

    # LIMIT 1 = the EARLIEST reference (created_at ASC).
    %{rows: [first]} =
      execute!(
        "SELECT conversation_id, sender_user_id FROM messages_by_media WHERE media_id = ? LIMIT 1",
        [media_id]
      )

    assert first["conversation_id"] == conv_earliest

    # The full partition read returns every reference with its sender — the oracle's input.
    %{rows: rows} =
      execute!(
        "SELECT conversation_id, sender_user_id FROM messages_by_media WHERE media_id = ?",
        [media_id]
      )

    assert length(rows) == 3
    assert Enum.count(rows, &(&1["sender_user_id"] == owner)) == 2

    # And an unrelated media_id shares nothing (partition isolation).
    %{rows: []} =
      execute!("SELECT media_id FROM messages_by_media WHERE media_id = ?", [Ecto.UUID.generate()])
  end

  # PROVES: partition = conversation_id alone; clustering = created_at DESC (a bare LIMIT page is
  # newest-first with no ORDER BY in the query); the cursor pattern `created_at < ?` pages backwards
  # along the clustering order; and INSERT on the same (conversation, created_at, message) REPLACES —
  # the primary-key identity C4's tombstone fan-out (deleted=true rewrite) depends on.
  # ASSUMES: nothing about `deleted` semantics — that invariant (denormalised copy, authority =
  # messages_by_conversation, reconciler owns convergence) is stated in the CQL header and the
  # adapter moduledoc, and is C4's to implement.
  test "media_by_conversation: newest-first gallery page, cursor paging, tombstone-rewrite identity" do
    conversation_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    insert = fn seconds_ago, deleted ->
      at = DateTime.add(now, -seconds_ago, :second)
      message_id = timeuuid_at(at)

      execute!(
        "INSERT INTO media_by_conversation " <>
          "(conversation_id, created_at, message_id, media_id, sender_user_id, deleted, metadata) " <>
          "VALUES (?, ?, ?, ?, ?, ?, ?)",
        [
          conversation_id,
          at,
          message_id,
          Ecto.UUID.generate(),
          Ecto.UUID.generate(),
          deleted,
          %{"content_type" => "\"image/png\""}
        ]
      )

      {at, message_id}
    end

    # Out-of-order inserts; expect newest-first reads.
    {_at3, _} = insert.(180, false)
    {at1, m1} = insert.(60, false)
    {_at4, _} = insert.(240, false)
    {at2, _} = insert.(120, false)

    %{rows: rows} =
      execute!(
        "SELECT message_id, created_at FROM media_by_conversation WHERE conversation_id = ? LIMIT 2",
        [conversation_id]
      )

    # Newest two, in DESC order, with NO ORDER BY in the query — that IS the clustering assertion.
    assert Enum.map(rows, & &1["created_at"]) ==
             [DateTime.truncate(at1, :millisecond), DateTime.truncate(at2, :millisecond)]

    # Cursor page: strictly older than the last row of page 1.
    %{rows: older} =
      execute!(
        "SELECT created_at FROM media_by_conversation " <>
          "WHERE conversation_id = ? AND created_at < ? LIMIT 10",
        [conversation_id, at2]
      )

    assert length(older) == 2
    assert Enum.all?(older, &(DateTime.compare(&1["created_at"], at2) == :lt))

    # TOMBSTONE-REWRITE IDENTITY: re-INSERT of the same primary key with deleted=true REPLACES the
    # row (no duplicate) — the exact write C4's delete fan-out will issue.
    execute!(
      "INSERT INTO media_by_conversation " <>
        "(conversation_id, created_at, message_id, media_id, sender_user_id, deleted, metadata) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [conversation_id, at1, m1, Ecto.UUID.generate(), Ecto.UUID.generate(), true, %{}]
    )

    %{rows: all_rows} =
      execute!(
        "SELECT message_id, deleted FROM media_by_conversation WHERE conversation_id = ?",
        [conversation_id]
      )

    assert length(all_rows) == 4, "same-key insert must REPLACE, not duplicate"
    assert Enum.count(all_rows, & &1["deleted"]) == 1
  end
end
