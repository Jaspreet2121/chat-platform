defmodule MessageService.InboxRepairTest do
  @moduledoc """
  The one-off repair's load-bearing properties, provable without production data: the staleness
  predicate (boundary-derived, and RE-CHECKED inside every UPDATE — the race guard), the
  clear-vs-rewrite split on store contents, the drift skip, unread zeroing, dry-run inertness, and
  idempotency. The store is the InboxFromTopicTest-style stub for the same recorded reason: the
  point read resolves from (conversation_id, message_id) alone.
  """
  use MessageService.DataCase, async: false

  alias MessageService.InboxRepair

  @tenant "00000000-0000-0000-0000-000000000001"

  defmodule StoreStub do
    @moduledoc false
    use Agent

    def start do
      case Agent.start_link(fn -> %{} end, name: __MODULE__) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end

    def reset, do: Agent.update(__MODULE__, fn _ -> %{} end)

    def put(message),
      do:
        Agent.update(
          __MODULE__,
          &Map.put(&1, {message.conversation_id, message.message_id}, message)
        )

    def get_message(attrs) do
      key = {attrs["conversation_id"], attrs["message_id"]}

      case Agent.get(__MODULE__, &Map.get(&1, key)) do
        nil -> {:error, :message_not_found}
        message -> {:ok, message}
      end
    end
  end

  setup do
    prev_store = Application.get_env(:message_service, :message_store_adapter)
    Application.put_env(:message_service, :message_store_adapter, StoreStub)
    StoreStub.start()
    StoreStub.reset()

    on_exit(fn ->
      if prev_store,
        do: Application.put_env(:message_service, :message_store_adapter, prev_store),
        else: Application.delete_env(:message_service, :message_store_adapter)
    end)

    :ok
  end

  # The boundary is max(created_at) over the sandbox's own `messages` rows — one frozen row defines
  # it, exactly as the frozen production table does.
  defp freeze_boundary! do
    boundary = DateTime.add(DateTime.utc_now(), -7 * 24 * 3600, :second)
    conversation = conversation!()

    Repo.query!(
      "INSERT INTO messages (message_id, conversation_id, app_id, sender_user_id, message_type, " <>
        "body, created_at) VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, " <>
        "$4::text::uuid, 'text', 'the frozen boundary row', $5)",
      [Ecto.UUID.generate(), conversation, @tenant, user!(), boundary]
    )

    boundary
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active')",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp conversation!(opts \\ []) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, last_message_at, " <>
        "last_message_body, last_message_type) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid, $4, $5, $6)",
      [
        id,
        @tenant,
        user!(),
        Keyword.get(opts, :last_message_at),
        Keyword.get(opts, :last_message_body),
        if(Keyword.get(opts, :last_message_body), do: "text")
      ]
    )

    id
  end

  defp participant!(conversation, opts \\ []) do
    id = user!()

    Repo.query!(
      "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at, " <>
        "unread_count, oldest_unread_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'member', now(), $3, $4)",
      [
        conversation,
        id,
        Keyword.get(opts, :unread_count, 0),
        Keyword.get(opts, :oldest_unread_at)
      ]
    )

    id
  end

  defp index!(conversation, message_id, created_at) do
    Repo.query!(
      "INSERT INTO message_search (message_id, conversation_id, sender_user_id, created_at, " <>
        "search_text) VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, $4, 'indexed')",
      [message_id, conversation, user!(), created_at]
    )
  end

  defp preview(conversation) do
    %{rows: [[at, body]]} =
      Repo.query!(
        "SELECT last_message_at, last_message_body FROM conversations WHERE id = $1::text::uuid",
        [conversation]
      )

    {at, body}
  end

  defp unread(conversation, user) do
    %{rows: [[count, watermark]]} =
      Repo.query!(
        "SELECT unread_count, oldest_unread_at FROM conversation_participants " <>
          "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
        [conversation, user]
      )

    {count, watermark}
  end

  defp run!(opts \\ []) do
    path =
      Path.join(System.tmp_dir!(), "inbox_repair_test_#{System.unique_integer([:positive])}.log")

    summary = InboxRepair.run(Keyword.merge([dry_run: false, path: path], opts))
    on_exit(fn -> File.rm(path) end)
    summary
  end

  @tag :postgres_integration
  test "stale preview with NOTHING in the store is CLEARED; a fresh preview is untouched" do
    boundary = freeze_boundary!()
    stale_at = DateTime.add(boundary, -3600, :second)
    fresh_at = DateTime.add(boundary, 3600, :second)

    stale = conversation!(last_message_at: stale_at, last_message_body: "frozen yee")
    fresh = conversation!(last_message_at: fresh_at, last_message_body: "projection wrote me")

    summary = run!()

    assert {nil, nil} = preview(stale)
    # THE RACE GUARD IS THE SAME PREDICATE: a post-boundary row is what a mid-repair projection
    # write produces, and it must survive.
    assert {_, "projection wrote me"} = preview(fresh)
    assert summary.previews_cleared >= 1
  end

  @tag :postgres_integration
  test "stale preview WITH store data is REWRITTEN from the store, not cleared" do
    boundary = freeze_boundary!()
    stale_at = DateTime.add(boundary, -3600, :second)
    live_at = DateTime.add(boundary, -600, :second)

    conversation = conversation!(last_message_at: stale_at, last_message_body: "frozen old")
    message_id = Ecto.UUID.generate()
    index!(conversation, message_id, live_at)

    StoreStub.put(%{
      conversation_id: conversation,
      message_id: message_id,
      sender_user_id: user!(),
      message_type: "text",
      body: "the store's newest live body",
      metadata: %{},
      status: "active",
      created_at: live_at,
      deleted_at: nil
    })

    summary = run!()

    assert {^live_at, "the store's newest live body"} = preview(conversation)
    assert summary.previews_rewritten == 1
    assert summary.previews_cleared == 0
  end

  @tag :postgres_integration
  test "a DRIFTED newest index row (absent in store) is SKIPPED — frozen preview left, reported" do
    boundary = freeze_boundary!()
    stale_at = DateTime.add(boundary, -3600, :second)

    conversation = conversation!(last_message_at: stale_at, last_message_body: "frozen kept")
    index!(conversation, Ecto.UUID.generate(), DateTime.add(boundary, -600, :second))
    # Nothing in the StoreStub: the index row is drift.

    summary = run!()

    assert {^stale_at, "frozen kept"} = preview(conversation)
    assert summary.skipped_drift == 1
    assert File.read!(summary.audit_file) =~ "SKIP DRIFT"
  end

  @tag :postgres_integration
  test "stale unread is ZEROED with watermark NULLed; fresh unread untouched" do
    boundary = freeze_boundary!()
    conversation = conversation!()

    stale_user =
      participant!(conversation,
        unread_count: 7,
        oldest_unread_at: DateTime.add(boundary, -60, :second)
      )

    fresh_user =
      participant!(conversation,
        unread_count: 3,
        oldest_unread_at: DateTime.add(boundary, 60, :second)
      )

    summary = run!()

    assert {0, nil} = unread(conversation, stale_user)
    assert {3, _not_nil} = unread(conversation, fresh_user)
    assert summary.unread_zeroed == 1
  end

  @tag :postgres_integration
  test "DRY RUN plans everything and writes NOTHING" do
    boundary = freeze_boundary!()
    stale_at = DateTime.add(boundary, -3600, :second)
    conversation = conversation!(last_message_at: stale_at, last_message_body: "still frozen")
    user = participant!(conversation, unread_count: 5, oldest_unread_at: stale_at)

    summary = run!(dry_run: true)

    assert summary.dry_run
    assert summary.previews_cleared == 1
    assert summary.unread_zeroed == 1
    # The plan is a plan: the rows are untouched.
    assert {^stale_at, "still frozen"} = preview(conversation)
    assert {5, ^stale_at} = unread(conversation, user)
    assert File.read!(summary.audit_file) =~ "DRY RUN"
  end

  @tag :postgres_integration
  test "IDEMPOTENT: the second run finds nothing to do — INCLUDING the rewrite path" do
    boundary = freeze_boundary!()
    stale_at = DateTime.add(boundary, -3600, :second)
    conversation = conversation!(last_message_at: stale_at, last_message_body: "frozen once")
    participant!(conversation, unread_count: 2, oldest_unread_at: stale_at)

    # A rewrite-path conversation whose newest live message PREDATES the boundary — the production
    # shape that broke the original idempotency claim: its correct preview keeps a pre-boundary
    # timestamp forever, so the stale predicate matches it on every run and only the no-op detector
    # (last_message_id already = the store's newest) stops it re-planning.
    live_at = DateTime.add(boundary, -600, :second)
    rewritten = conversation!(last_message_at: stale_at, last_message_body: "frozen old")
    message_id = Ecto.UUID.generate()
    index!(rewritten, message_id, live_at)

    StoreStub.put(%{
      conversation_id: rewritten,
      message_id: message_id,
      sender_user_id: user!(),
      message_type: "text",
      body: "pre-boundary but correct",
      metadata: %{},
      status: "active",
      created_at: live_at,
      deleted_at: nil
    })

    first = run!()
    assert first.previews_cleared == 1
    assert first.previews_rewritten == 1
    assert first.unread_zeroed == 1
    assert {^live_at, "pre-boundary but correct"} = preview(rewritten)

    second = run!()
    assert second.previews_cleared == 0
    assert second.previews_rewritten == 0
    assert second.unread_zeroed == 0
  end

  @tag :postgres_integration
  test "the no-op detector must not fall through to an OLDER index row" do
    # The near-bug the detector's placement avoids: filtering `current_id <> message_id` INSIDE the
    # DISTINCT ON's WHERE would drop the newest row and let the second-newest through — planning a
    # BACKWARDS rewrite for exactly the conversations that need none. The filter sits outside.
    boundary = freeze_boundary!()
    live_at = DateTime.add(boundary, -600, :second)
    older_at = DateTime.add(boundary, -1200, :second)

    newest_id = Ecto.UUID.generate()
    older_id = Ecto.UUID.generate()

    conversation = conversation!(last_message_at: live_at, last_message_body: "already correct")

    Repo.query!(
      "UPDATE conversations SET last_message_id = $2::text::uuid WHERE id = $1::text::uuid",
      [conversation, newest_id]
    )

    index!(conversation, newest_id, live_at)
    index!(conversation, older_id, older_at)

    # The OLDER message exists in the store too — without this the fall-through would dead-end in
    # the drift skip and the test would pass even with the detector misplaced, proving nothing.
    StoreStub.put(%{
      conversation_id: conversation,
      message_id: older_id,
      sender_user_id: user!(),
      message_type: "text",
      body: "the OLDER body a backwards rewrite would install",
      metadata: %{},
      status: "active",
      created_at: older_at,
      deleted_at: nil
    })

    summary = run!()

    assert summary.previews_rewritten == 0
    assert {^live_at, "already correct"} = preview(conversation)
  end

  @tag :postgres_integration
  test "the audit file carries before/after per row" do
    boundary = freeze_boundary!()
    stale_at = DateTime.add(boundary, -3600, :second)
    conversation = conversation!(last_message_at: stale_at, last_message_body: "audited body")
    participant!(conversation, unread_count: 9, oldest_unread_at: stale_at)

    summary = run!()
    audit = File.read!(summary.audit_file)

    assert audit =~ "PREVIEW CLEAR conv=#{conversation}"
    assert audit =~ "audited body"
    assert audit =~ "before=9"
  end
end
