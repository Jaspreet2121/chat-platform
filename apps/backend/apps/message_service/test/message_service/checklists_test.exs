defmodule MessageService.ChecklistsTest do
  @moduledoc """
  Checklist messages (126) on the REAL create/tick/add path and real rows.

  The rules that matter: the caps hold (MUT-5), permission is author-only unless `others_can_check` /
  `others_can_add` (MUT-2), a stale `if_unchanged_since` never overwrites a newer tick (MUT-3), a
  sealed conversation refuses with its own name (MUT-6), and a tick NEVER touches the inbox preview
  (MUT-7 — the design pin: `conversations` is not written on every tap).
  """
  use MessageService.DataCase, async: false

  alias MessageService.{Checklists, Messages}

  @tenant "00000000-0000-0000-0000-000000000001"

  setup do
    prev = Application.get_env(:message_service, :message_persistence, false)

    prev_adapter =
      Application.get_env(
        :message_service,
        :message_store_adapter,
        MessageService.MessageStore.QueryPlanAdapter
      )

    Application.put_env(:message_service, :message_persistence, true)

    Application.put_env(
      :message_service,
      :message_store_adapter,
      MessageService.MessageStore.PostgresAdapter
    )

    on_exit(fn ->
      Application.put_env(:message_service, :message_persistence, prev)
      Application.put_env(:message_service, :message_store_adapter, prev_adapter)
    end)

    :ok
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active', now(), now())",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp conversation!(members, secret \\ false) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, status, secret, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid, 'active', $4, now(), now())",
      [id, @tenant, hd(members), secret]
    )

    for member <- members do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
        [id, member]
      )
    end

    id
  end

  defp create!(conversation_id, author, definition, title \\ "Groceries") do
    Messages.create_message(%{
      "conversation_id" => conversation_id,
      "sender_user_id" => author,
      "message_type" => "checklist",
      "body" => title,
      "metadata" => %{"checklist" => definition}
    })
  end

  defp items(list), do: %{"items" => Enum.map(list, &%{"text" => &1})}

  defp tick(conversation_id, message_id, item_id, user_id, done, token) do
    Checklists.tick(%{
      "conversation_id" => conversation_id,
      "message_id" => message_id,
      "item_id" => item_id,
      "user_id" => user_id,
      "done" => done,
      "if_unchanged_since" => token
    })
  end

  defp preview(conversation_id) do
    %{rows: [[body, type]]} =
      Repo.query!(
        "SELECT last_message_body, last_message_type FROM conversations WHERE id = $1::text::uuid",
        [conversation_id]
      )

    {body, type}
  end

  @tag :postgres_integration
  test "CREATE: body is the title, metadata is the rebuilt definition, the ack carries a zero aggregate" do
    author = user!()
    conversation = conversation!([author])

    assert {:ok, ack} =
             create!(
               conversation,
               author,
               Map.merge(items(["milk", "eggs"]), %{"others_can_check" => true}),
               "Groceries"
             )

    assert ack.message_type == "checklist"
    assert ack.body == "Groceries"

    assert ack.metadata["checklist"]["items"] == [
             %{"id" => "i1", "text" => "milk"},
             %{"id" => "i2", "text" => "eggs"}
           ]

    assert ack.metadata["checklist"]["others_can_check"] == true
    assert ack.metadata["checklist"]["others_can_add"] == false

    assert ack.checklist.done_count == 0
    assert ack.checklist.total == 2
    assert Enum.map(ack.checklist.items, & &1.id) == ["i1", "i2"]
    assert Enum.all?(ack.checklist.items, &(&1.done == false and &1.done_by == nil))
  end

  @tag :postgres_integration
  test "TICK: done_by is recorded and PUBLIC, the aggregate counts, and the TIMELINE carries it" do
    author = user!()
    peer = user!()
    conversation = conversation!([author, peer])

    {:ok, ack} =
      create!(
        conversation,
        author,
        Map.merge(items(["milk", "eggs"]), %{"others_can_check" => true})
      )

    assert {:ok, ticked} = tick(conversation, ack.message_id, "i1", peer, true, nil)
    assert ticked.checklist.done_count == 1
    assert ticked.checklist.total == 2

    done = Enum.find(ticked.checklist.items, &(&1.id == "i1"))
    assert done.done == true
    assert done.done_by == peer
    assert is_binary(done.done_at)

    {:ok, %{messages: [row]}} =
      Messages.list_messages(%{"conversation_id" => conversation, "viewer_user_id" => author})

    assert row.checklist.done_count == 1
    assert row.checklist.total == 2
    assert Enum.find(row.checklist.items, &(&1.id == "i1")).done_by == peer
  end

  @tag :postgres_integration
  test "MUT-2 guard: CREATE writes the title as the inbox preview — it was NULL on device" do
    author = user!()
    conversation = conversation!([author])

    assert {:ok, _} = create!(conversation, author, items(["milk"]), "Weekend shop")

    # The DENORMALISED column the list reads …
    assert preview(conversation) == {"Weekend shop", "checklist"}

    # … and the row the client actually receives, through the SAME mapper the broadcast uses.
    assert SharedInfra.InboxPreview.preview_text("Weekend shop", "checklist") == "Weekend shop"
  end

  @tag :postgres_integration
  test "MUT-7 guard: a tick NEVER writes the inbox preview — the title stays, the count does not ride it" do
    author = user!()
    conversation = conversation!([author])

    {:ok, ack} =
      create!(conversation, author, items(["milk", "eggs", "bread"]), "Weekend shop")

    assert preview(conversation) == {"Weekend shop", "checklist"}

    assert {:ok, _} = tick(conversation, ack.message_id, "i1", author, true, nil)
    assert {:ok, _} = tick(conversation, ack.message_id, "i2", author, true, nil)

    # Byte-identical: the title alone, with no count appended and no rewrite of any kind.
    assert preview(conversation) == {"Weekend shop", "checklist"}
  end

  @tag :postgres_integration
  test "MUT-2 guard: others_can_check=false → only the AUTHOR may tick" do
    author = user!()
    peer = user!()
    conversation = conversation!([author, peer])

    {:ok, ack} = create!(conversation, author, items(["milk"]))

    assert {:error, :checklist_not_allowed} =
             tick(conversation, ack.message_id, "i1", peer, true, nil)

    assert {:ok, _} = tick(conversation, ack.message_id, "i1", author, true, nil)
  end

  @tag :postgres_integration
  test "MUT-3 guard: a STALE if_unchanged_since is refused with the CURRENT state, never applied" do
    author = user!()
    peer = user!()
    conversation = conversation!([author, peer])

    {:ok, ack} =
      create!(conversation, author, Map.merge(items(["milk"]), %{"others_can_check" => true}))

    # The author ticks; the item now has a done_at.
    assert {:ok, first} = tick(conversation, ack.message_id, "i1", author, true, nil)
    current = Enum.find(first.checklist.items, &(&1.id == "i1")).done_at
    assert is_binary(current)

    # The peer still believes it is UNDONE (token nil) and tries to tick — refused with the truth.
    assert {:error, :checklist_stale, item} =
             tick(conversation, ack.message_id, "i1", peer, false, nil)

    assert item.done == true
    assert item.done_by == author
    assert item.done_at == current

    # The stored state is untouched: the stale write was not applied.
    {:ok, %{messages: [row]}} =
      Messages.list_messages(%{"conversation_id" => conversation, "viewer_user_id" => author})

    stored = Enum.find(row.checklist.items, &(&1.id == "i1"))
    assert stored.done == true
    assert stored.done_by == author

    # With the CORRECT token the same untick succeeds.
    assert {:ok, second} = tick(conversation, ack.message_id, "i1", peer, false, current)
    assert Enum.find(second.checklist.items, &(&1.id == "i1")).done == false
  end

  @tag :postgres_integration
  test "the token is REQUIRED — a tick that never read the item is refused" do
    author = user!()
    conversation = conversation!([author])
    {:ok, ack} = create!(conversation, author, items(["milk"]))

    assert {:error, :checklist_stale_token_missing} =
             Checklists.tick(%{
               "conversation_id" => conversation,
               "message_id" => ack.message_id,
               "item_id" => "i1",
               "user_id" => author,
               "done" => true
             })
  end

  @tag :postgres_integration
  test "ADD: author always; others only when others_can_add; the item joins the aggregate in order" do
    author = user!()
    peer = user!()
    conversation = conversation!([author, peer])

    {:ok, closed} = create!(conversation, author, items(["milk"]))

    assert {:error, :checklist_not_allowed} =
             Checklists.add_item(%{
               "conversation_id" => conversation,
               "message_id" => closed.message_id,
               "user_id" => peer,
               "text" => "eggs"
             })

    {:ok, open} =
      create!(conversation, author, Map.merge(items(["milk"]), %{"others_can_add" => true}))

    assert {:ok, added} =
             Checklists.add_item(%{
               "conversation_id" => conversation,
               "message_id" => open.message_id,
               "user_id" => peer,
               "text" => "eggs"
             })

    assert added.checklist.total == 2
    assert Enum.map(added.checklist.items, & &1.text) == ["milk", "eggs"]

    # An ADDED item is tickable like any other.
    added_id = Enum.at(added.checklist.items, 1).id
    assert {:ok, ticked} = tick(conversation, open.message_id, added_id, author, true, nil)
    assert ticked.checklist.done_count == 1
  end

  @tag :postgres_integration
  test "MUT-5 guard: the CAPS hold on create and on add" do
    author = user!()
    conversation = conversation!([author])

    # > 30 items at create.
    too_many = items(Enum.map(1..31, &"item #{&1}"))
    assert {:error, :checklist_too_many_items} = create!(conversation, author, too_many)

    # > 200 characters at create.
    long = items([String.duplicate("x", 201)])
    assert {:error, :checklist_text_too_long} = create!(conversation, author, long)

    # Exactly at the cap is fine …
    at_cap = items(Enum.map(1..30, &"item #{&1}"))
    assert {:ok, full} = create!(conversation, author, at_cap)
    assert full.checklist.total == 30

    # … and one more via ADD is refused.
    assert {:error, :checklist_too_many_items} =
             Checklists.add_item(%{
               "conversation_id" => conversation,
               "message_id" => full.message_id,
               "user_id" => author,
               "text" => "one too many"
             })

    # 200 characters exactly is accepted; 201 via add is refused.
    {:ok, small} = create!(conversation, author, items(["milk"]))

    assert {:ok, _} =
             Checklists.add_item(%{
               "conversation_id" => conversation,
               "message_id" => small.message_id,
               "user_id" => author,
               "text" => String.duplicate("y", 200)
             })

    assert {:error, :checklist_text_too_long} =
             Checklists.add_item(%{
               "conversation_id" => conversation,
               "message_id" => small.message_id,
               "user_id" => author,
               "text" => String.duplicate("y", 201)
             })
  end

  @tag :postgres_integration
  test "MUT-6 guard: a checklist in a SEALED conversation is refused by NAME" do
    author = user!()
    secret = conversation!([author], true)

    assert {:error, :checklist_not_in_sealed} = create!(secret, author, items(["milk"]))

    # And a plain conversation still accepts one.
    open = conversation!([author])
    assert {:ok, _} = create!(open, author, items(["milk"]))
  end

  @tag :postgres_integration
  test "an empty list, a blank title and an unknown item are each refused" do
    author = user!()
    conversation = conversation!([author])

    assert {:error, :checklist_no_items} = create!(conversation, author, %{"items" => []})
    assert {:error, :checklist_invalid_item} = create!(conversation, author, items(["   "]))

    assert {:error, :checklist_invalid_title} =
             create!(conversation, author, items(["milk"]), "  ")

    {:ok, ack} = create!(conversation, author, items(["milk"]))

    assert {:error, :checklist_item_not_found} =
             tick(conversation, ack.message_id, "i99", author, true, nil)
  end

  @tag :postgres_integration
  test "a tick on a message in ANOTHER conversation is not found — no cross-conversation reach" do
    author = user!()
    mine = conversation!([author])
    theirs = conversation!([author])

    {:ok, ack} = create!(mine, author, items(["milk"]))

    assert {:error, :message_not_found} = tick(theirs, ack.message_id, "i1", author, true, nil)
  end
end
