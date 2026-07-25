defmodule ConversationService.BlocksTest do
  @moduledoc """
  `user_blocks` CRUD + the enforcement predicates, against real Postgres (`@tag :postgres_integration` — the
  logic IS SQL, a stubbed adapter would only test the stub). Covers: block/unblock idempotency, `either_blocked?`
  symmetry (both directions), the directional `blocked?`, and — the one that proves the block is NOT
  over-applied — `direct_peer_blocked?` returning TRUE for a DIRECT chat with a block but FALSE for a GROUP
  with the SAME block (a blocked user may still post to a shared group). Plus the self/unknown guards.

  Fixtures are raw SQL (these tables are shared and have no local schemas here), mirroring InboxRowsTest.
  """
  use ConversationService.DataCase, async: false

  alias ConversationService.Blocks

  setup do
    previous = Application.get_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:conversation_service, :conversation_persistence, true)
    on_exit(fn -> Application.put_env(:conversation_service, :conversation_persistence, previous) end)
    :ok
  end

  defp user!(name) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, email, password_hash, created_at, updated_at) VALUES ($1::text::uuid, $2, 'x', now(), now())",
      [id, "#{name}-#{id}@test.local"]
    )

    id
  end

  defp conversation!(type, created_by) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, type, title, created_by, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2, NULL, $3::text::uuid, 'active', now(), now())",
      [id, type, created_by]
    )

    id
  end

  defp participant!(conversation_id, user_id) do
    Repo.query!(
      "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
      [conversation_id, user_id]
    )
  end

  defp block!(blocker, blocked),
    do: Blocks.block(%{"blocker_user_id" => blocker, "blocked_user_id" => blocked})

  defp either?(a, b) do
    {:ok, %{blocked: blocked}} = Blocks.either_blocked?(%{"user_a" => a, "user_b" => b})
    blocked
  end

  defp direct_peer_blocked?(conversation_id, user_id) do
    {:ok, %{blocked: blocked}} =
      Blocks.direct_peer_blocked?(%{"conversation_id" => conversation_id, "user_id" => user_id})

    blocked
  end

  @tag :postgres_integration
  test "block is idempotent; either_blocked? sees BOTH directions; blocked? is directional; unblock clears it" do
    a = user!("a")
    b = user!("b")

    refute either?(a, b)

    assert {:ok, _} = block!(a, b)
    # Re-block is a no-op (PK ON CONFLICT) — still :ok.
    assert {:ok, _} = block!(a, b)

    # Symmetric: a block by a-on-b is visible from either side.
    assert either?(a, b)
    assert either?(b, a)

    # Directional blocked?: only a→b, not b→a.
    assert {:ok, %{blocked: true}} = Blocks.blocked?(%{"blocker_user_id" => a, "blocked_user_id" => b})
    assert {:ok, %{blocked: false}} = Blocks.blocked?(%{"blocker_user_id" => b, "blocked_user_id" => a})

    assert {:ok, _} = Blocks.unblock(%{"blocker_user_id" => a, "blocked_user_id" => b})
    refute either?(a, b)
  end

  @tag :postgres_integration
  test "self-block → :block_self; an unknown blocked user → :block_unknown_user (FK), never a crash" do
    a = user!("a")

    assert {:error, :block_self} = block!(a, a)
    assert {:error, :block_unknown_user} = block!(a, Ecto.UUID.generate())
  end

  @tag :postgres_integration
  test "direct_peer_blocked?: TRUE in a DIRECT chat with a block, FALSE in a GROUP (block NOT over-applied)" do
    a = user!("a")
    b = user!("b")
    block!(a, b)

    direct = conversation!("direct", a)
    participant!(direct, a)
    participant!(direct, b)

    # Either party sending in the blocked DIRECT chat → dropped.
    assert direct_peer_blocked?(direct, a)
    assert direct_peer_blocked?(direct, b)

    group = conversation!("group", a)
    participant!(group, a)
    participant!(group, b)

    # SAME block, but a GROUP → NOT dropped. A blocked user still posts to a shared group (WhatsApp), and the
    # blocker sees those group messages normally.
    refute direct_peer_blocked?(group, a)
    refute direct_peer_blocked?(group, b)
  end

  @tag :postgres_integration
  test "direct_peer_blocked? is FALSE with no block (normal delivery)" do
    a = user!("a")
    b = user!("b")
    direct = conversation!("direct", a)
    participant!(direct, a)
    participant!(direct, b)

    refute direct_peer_blocked?(direct, a)
  end

  @tag :postgres_integration
  test "list_blocks returns the blocked users (newest first) with created_at" do
    a = user!("a")
    b = user!("b")
    c = user!("c")
    block!(a, b)
    block!(a, c)

    assert {:ok, %{blocks: blocks}} = Blocks.list_blocks(%{"blocker_user_id" => a})
    assert Enum.sort(Enum.map(blocks, & &1.user_id)) == Enum.sort([b, c])
    assert Enum.all?(blocks, &is_binary(&1.created_at))
  end
end
