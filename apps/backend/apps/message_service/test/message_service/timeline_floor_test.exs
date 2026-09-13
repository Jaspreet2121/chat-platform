defmodule MessageService.TimelineFloorTest do
  @moduledoc """
  THE AGE BOUND on the Scylla timeline walk, measured in point reads.

  A page that could not fill in its first 7-day window used to walk to the 730-day cap: 730
  sequential Scylla reads for every conversation with fewer than 50 messages, ~225 ms per open in
  production. The bound stops the walk the day before the conversation was created.

  The floor is a REAL Postgres row (the conversation's created_at, read through
  ConversationRow) — the Scylla side is a fake client that answers per bucket from memory and
  COUNTS every timeline read, so "how many buckets did this page touch" is a measured number, not
  an inference. No Scylla is needed; the real-engine ordering/cursor semantics stay pinned by
  ScyllaStoreIntegrationTest, which this does not replace.
  """
  use MessageService.DataCase, async: false

  alias MessageService.MessageStore.ScyllaAdapter

  @tenant "00000000-0000-0000-0000-000000000001"

  # ---- the fake Scylla: rows per bucket, every timeline read counted ---------------------------------

  defmodule FakeScylla do
    @moduledoc false
    def start_link, do: Agent.start_link(fn -> %{rows: %{}, reads: 0} end, name: __MODULE__)

    # Keyed by {conversation_id, bucket}, exactly as the partition key is — two conversations never
    # see each other's rows.
    def put(conversation_id, bucket, row) do
      Agent.update(__MODULE__, fn state ->
        update_in(state, [:rows, {conversation_id, bucket}], fn rs -> [row | rs || []] end)
      end)
    end

    def reads, do: Agent.get(__MODULE__, & &1.reads)
    def reset_reads, do: Agent.update(__MODULE__, &%{&1 | reads: 0})

    # execute(statement, params, opts) — the SharedInfra.Scylla.Client contract the adapter calls.
    def execute(statement, params, _opts) do
      if String.contains?(statement, "FROM messages_by_conversation") do
        {cid, bucket, before_id, limit} =
          case params do
            [cid, %Date{} = b, limit] -> {cid, b, nil, limit}
            [cid, %Date{} = b, before_id, limit] -> {cid, b, before_id, limit}
          end

        Agent.update(__MODULE__, &%{&1 | reads: &1.reads + 1})

        rows =
          Agent.get(__MODULE__, &Map.get(&1.rows, {cid, bucket}, []))
          |> Enum.sort_by(&ts/1, :desc)
          |> Enum.filter(fn r -> before_id == nil or ts(r) < ts(%{"message_id" => before_id}) end)
          |> Enum.take(limit)

        {:ok, %{rows: rows}}
      else
        # receipts, etc. — nothing to say
        {:ok, %{rows: []}}
      end
    end

    defp ts(row) do
      {:ok, dt} = MessageService.Persistence.ScyllaCodec.timeuuid_to_datetime(row["message_id"])
      DateTime.to_unix(dt, :microsecond)
    end
  end

  # A v1 timeuuid whose embedded timestamp is `dt` — the inverse of ScyllaCodec.timeuuid_to_datetime.
  defp timeuuid_at(%DateTime{} = dt) do
    import Bitwise
    hundred_ns = DateTime.to_unix(dt, :microsecond) * 10 + 0x01B21DD213814000
    low = band(hundred_ns, 0xFFFFFFFF)
    mid = band(bsr(hundred_ns, 32), 0xFFFF)
    hi = bor(band(bsr(hundred_ns, 48), 0x0FFF), 0x1000)
    node = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)

    hex = fn n, w ->
      n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(w, "0")
    end

    "#{hex.(low, 8)}-#{hex.(mid, 4)}-#{hex.(hi, 4)}-8000-#{node}"
  end

  defp plant!(conversation_id, sender, %DateTime{} = at, body, id \\ nil) do
    id = id || timeuuid_at(at)

    FakeScylla.put(conversation_id, DateTime.to_date(at), %{
      "conversation_id" => conversation_id,
      "message_id" => id,
      "sender_user_id" => sender,
      "message_type" => "text",
      "body" => body,
      "media_id" => nil,
      "reply_to_message_id" => nil,
      "status" => "active",
      "metadata" => %{},
      "view_once" => false,
      "created_at" => at,
      "edited_at" => nil,
      "deleted_at" => nil
    })

    id
  end

  defp days_ago(n, hour \\ 12),
    do:
      DateTime.utc_now()
      |> DateTime.add(-n * 86_400, :second)
      |> then(&%{&1 | hour: hour, minute: 0, second: 0, microsecond: {0, 0}})

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status) VALUES ($1::text::uuid, $2::text::uuid, $3, 'active')",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  # The REAL floor input: a conversations row with this created_at.
  defp conversation!(creator, %DateTime{} = created_at) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, created_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'direct', $3::text::uuid, $4)",
      [id, @tenant, creator, created_at]
    )

    id
  end

  defp page(conversation_id, viewer, extra \\ %{}) do
    FakeScylla.reset_reads()

    {:ok, %{messages: messages, next_cursor: cursor}} =
      ScyllaAdapter.list_messages(
        Map.merge(
          %{"conversation_id" => conversation_id, "viewer_user_id" => viewer, "limit" => 50},
          extra
        )
      )

    {messages, cursor, FakeScylla.reads()}
  end

  setup do
    start_supervised!(%{id: FakeScylla, start: {FakeScylla, :start_link, []}})
    previous = Application.get_env(:message_service, :scylla_client_adapter)
    Application.put_env(:message_service, :scylla_client_adapter, FakeScylla)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:message_service, :scylla_client_adapter, previous),
        else: Application.delete_env(:message_service, :scylla_client_adapter)
    end)

    :ok
  end

  # ---- the bound -------------------------------------------------------------------------------------

  @tag :postgres_integration
  test "a 10-day-old, 5-message conversation walks ≤ 21 buckets — not 730" do
    a = user!()
    conv = conversation!(a, days_ago(10))
    for d <- [0, 0, 1, 2, 2], do: plant!(conv, a, days_ago(d), "m#{d}")

    {messages, cursor, reads} = page(conv, a)

    assert length(messages) == 5
    assert cursor == nil, "fewer than a page: the walk ended, no cursor"

    # Window 1 = 7 buckets (today..−6); window 2 is clipped at the floor (created −1 = −11):
    # −7..−11 = 5 buckets. 12 reads. Anything near 730 means the bound is not applied.
    assert reads <= 21,
           "#{reads} Scylla point reads for a 10-day-old conversation — the walk ran past the " <>
             "conversation's own age towards the 730-day cap"
  end

  @tag :postgres_integration
  test "a message bucketed the day BEFORE created_at is still returned — one day of skew slack" do
    a = user!()
    # 00:30 UTC, five days ago
    created = days_ago(5, 0) |> DateTime.add(30 * 60, :second)
    conv = conversation!(a, created)

    # Minted moments before the Postgres row committed, on the previous UTC day — the skew case.
    skewed = plant!(conv, a, DateTime.add(created, -45 * 60, :second), "skewed")
    plant!(conv, a, days_ago(1), "normal")

    {messages, _cursor, _reads} = page(conv, a)

    assert Enum.map(messages, & &1.message_id) |> Enum.member?(skewed),
           "the message in the bucket before created_at was dropped — the floor has no skew slack"

    assert length(messages) == 2
  end

  @tag :postgres_integration
  test "an UNKNOWN conversation row falls back to the 730-day cap — the page still renders" do
    a = user!()
    # no conversations row at all
    ghost = Ecto.UUID.generate()

    {messages, cursor, reads} = page(ghost, a)

    assert messages == []
    assert cursor == nil
    # The cap is the ONLY bound when the row is unknown: 105 windows of 7 (the 730-day check runs
    # per window, so the last one overshoots by five days) = 735 reads — and a page, never an error.
    assert reads == 735
  end

  @tag :postgres_integration
  test "a cursor anchored BEFORE the floor is a page with nothing under it — zero reads" do
    a = user!()
    conv = conversation!(a, days_ago(10))

    # A row that could not legitimately exist (before the conversation did) — planted to prove the
    # bound is applied to cursor pages, not only to the first page.
    stray = plant!(conv, a, days_ago(20), "stray")
    plant!(conv, a, days_ago(1), "real")

    anchor = days_ago(20) |> DateTime.to_date() |> Date.to_iso8601()
    {messages, cursor, reads} = page(conv, a, %{"before" => "#{anchor}|#{stray}"})

    assert messages == [],
           "a page anchored before the conversation existed returned rows — the bound skips " <>
             "cursor pages"

    assert cursor == nil
    assert reads == 0
  end

  # ---- the pin: a dense conversation is byte-identical with or without the bound -------------------

  @tag :postgres_integration
  test "a dense conversation (60 msgs / 2 days) returns the SAME page bound or not, in 7 reads" do
    a = user!()
    bounded = conversation!(a, days_ago(30))
    # No conversations row → no floor → the walk exactly as it always was.
    unbounded = Ecto.UUID.generate()

    # The SAME 60 rows, same ids, in both conversations, so the two pages compare byte for byte.
    planted =
      for i <- 0..59 do
        at = days_ago(rem(i, 2)) |> DateTime.add(i * 37, :second)
        id = timeuuid_at(at)
        plant!(bounded, a, at, "d#{i}", id)
        plant!(unbounded, a, at, "d#{i}", id)
        {id, at}
      end

    {page_b, cursor_b, reads_b} = page(bounded, a)
    {page_u, cursor_u, reads_u} = page(unbounded, a)

    strip = fn ms -> Enum.map(ms, &Map.drop(&1, [:conversation_id])) end
    assert strip.(page_b) == strip.(page_u), "the bound changed a page that fills in window 1"
    assert cursor_b == cursor_u
    assert length(page_b) == 50
    assert String.ends_with?(cursor_b, "|" <> List.last(page_b).message_id)
    assert reads_b == 7 and reads_u == 7, "a page that fills in window 1 is exactly one window"

    # Newest first, by the timeuuid's embedded time — the two buckets interleave by planting index,
    # so the expectation is sorted by timestamp, not by write order.
    expected =
      planted
      |> Enum.sort_by(fn {_id, at} -> DateTime.to_unix(at, :microsecond) end, :desc)
      |> Enum.map(&elem(&1, 0))
      |> Enum.take(50)

    assert Enum.map(page_b, & &1.message_id) == expected
  end
end
