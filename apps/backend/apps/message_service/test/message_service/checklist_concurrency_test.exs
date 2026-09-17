defmodule MessageService.ChecklistConcurrencyTest do
  @moduledoc """
  TWO PEOPLE TAPPING THE SAME ROW. The stale check used to be a SELECT, an in-Elixir comparison and
  then an upsert: both callers could pass the SELECT before either wrote, and both "succeeded" —
  the second silently overwriting the first, which is exactly what the token exists to prevent.

  The check is now the WHERE clause of the write, so it is evaluated under the row lock. This test
  runs two REAL concurrent transactions against real Postgres — not two sequential calls, which
  would pass even against the broken code.
  """
  # NOT DataCase: its per-test sandbox transaction would hide the race entirely — two processes
  # inside one transaction cannot contend for a row lock. This suite runs the repo in :auto mode so
  # the writes are real, and cleans up its own rows.
  use ExUnit.Case, async: false

  alias MessageService.{Checklists, Messages}
  alias MessageService.Repo

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

    case Repo.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    # :auto — every query runs on its own real connection and COMMITS, which is the only way two
    # processes can actually contend for the same row.
    previous_mode = Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    _ = previous_mode

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
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

  defp conversation!(members) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid, 'active', now(), now())",
      [id, @tenant, hd(members)]
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

  defp tick(conversation_id, message_id, user_id, token) do
    Checklists.tick(%{
      "conversation_id" => conversation_id,
      "message_id" => message_id,
      "item_id" => "i1",
      "user_id" => user_id,
      "done" => true,
      "if_unchanged_since" => token
    })
  end

  @tag :postgres_integration
  test "MUT-4 guard: two CONCURRENT ticks with the same token — exactly one wins, the other is told" do
    author = user!()
    peer = user!()
    conversation = conversation!([author, peer])

    {:ok, ack} =
      Messages.create_message(%{
        "conversation_id" => conversation,
        "sender_user_id" => author,
        "message_type" => "checklist",
        "body" => "Race",
        "metadata" => %{
          "checklist" => %{"items" => [%{"text" => "the one item"}], "others_can_check" => true}
        }
      })

    # Both believe the item is NOT done — the same token, which is the real-world shape: two people
    # looking at the same rendered list.
    tasks =
      for user_id <- [author, peer] do
        Task.async(fn ->
          # Line them up so neither can finish before the other starts.
          Process.sleep(:rand.uniform(15))
          tick(conversation, ack.message_id, user_id, nil)
        end)
      end

    results = Task.await_many(tasks, 15_000)

    winners = Enum.count(results, &match?({:ok, _}, &1))
    losers = Enum.count(results, &match?({:error, :checklist_stale, _}, &1))

    assert winners == 1,
           "expected exactly one tick to win, got #{winners}: #{inspect(results)}"

    assert losers == 1,
           "expected the other tick to be told it was stale, got: #{inspect(results)}"

    # The loser was handed the CURRENT truth, not an empty refusal.
    {:error, :checklist_stale, item} =
      Enum.find(results, &match?({:error, :checklist_stale, _}, &1))

    assert item.done == true
    assert item.done_by in [author, peer]
    assert is_binary(item.done_at)

    # And the stored row agrees with whoever won — one done_by, not a last-write-wins smear.
    %{rows: [[done, done_by]]} =
      Repo.query!(
        "SELECT done, done_by::text FROM checklist_items " <>
          "WHERE message_id = $1::text::uuid AND item_id = 'i1'",
        [ack.message_id]
      )

    assert done == true
    assert done_by == item.done_by

    Repo.query!("DELETE FROM checklist_items WHERE message_id = $1::text::uuid", [ack.message_id])
    Repo.query!("DELETE FROM messages WHERE conversation_id = $1::text::uuid", [conversation])

    Repo.query!("DELETE FROM conversation_participants WHERE conversation_id = $1::text::uuid", [
      conversation
    ])

    Repo.query!("DELETE FROM conversations WHERE id = $1::text::uuid", [conversation])
    Repo.query!("DELETE FROM users_auth WHERE id = ANY($1::text[]::uuid[])", [[author, peer]])
  end
end
