defmodule MessageService.PostgresMessageCursorTest do
  @moduledoc """
  Compound (created_at, message_id) keyset pagination for the Postgres message store (the /v1 backfill
  path). The headline case is SAME-TIMESTAMP correctness: two messages sharing a created_at must page
  without skipping — a bare-timestamp cursor (created_at > T) would drop the second one. Exercises the
  public MessageService boundary so the cursor threads exactly as it does from the /v1 controller.
  """
  use MessageService.DataCase, async: false

  import Ecto.Query

  alias MessageService.{Messages, MessageStore, Repo}
  alias MessageService.Schemas.Message

  @conversation_id "33333333-3333-4333-8333-333333333333"
  @sender "44444444-4444-4444-8444-444444444444"
  @app_id "55555555-5555-4555-8555-555555555555"
  # A uuid that sorts strictly before any real message id → a "from the beginning" forward anchor.
  @min_uuid "00000000-0000-0000-0000-000000000000"
  @shared_ts ~U[2026-01-01 00:00:00.000000Z]

  setup do
    previous_persistence = Application.get_env(:message_service, :message_persistence, false)

    previous_adapter =
      Application.get_env(:message_service, :message_store_adapter, MessageStore.QueryPlanAdapter)

    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:message_service, :message_store_adapter, MessageStore.PostgresAdapter)

    on_exit(fn ->
      Application.put_env(:message_service, :message_persistence, previous_persistence)
      Application.put_env(:message_service, :message_store_adapter, previous_adapter)
    end)

    # Messages resolve their authoritative app_id from the parent conversation (migration 056) — an
    # unknown conversation is rejected as :message_invalid. Seed the FK chain so create_message works:
    # apps ← users_auth ← conversations (and messages.app_id → apps). All rolled back with the test by
    # the SQL Sandbox.
    Repo.query!(
      "INSERT INTO apps (id, name, slug) VALUES ($1::text::uuid, 'cursor-test', 'cursor-test') " <>
        "ON CONFLICT (id) DO NOTHING",
      [@app_id]
    )

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, external_id) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'cursor-test-sender') ON CONFLICT (id) DO NOTHING",
      [@sender, @app_id]
    )

    Repo.query!(
      "INSERT INTO conversations (id, type, created_by, app_id) " <>
        "VALUES ($1::text::uuid, 'direct', $2::text::uuid, $3::text::uuid) ON CONFLICT (id) DO NOTHING",
      [@conversation_id, @sender, @app_id]
    )

    :ok
  end

  defp create!(body) do
    {:ok, message} =
      Messages.create_message(%{
        "conversation_id" => @conversation_id,
        "sender_user_id" => @sender,
        "message_type" => "text",
        "body" => body
      })

    message
  end

  # Force two rows onto the SAME created_at (create_message stamps now(), which is unique). Returns the
  # two message_ids in the order Postgres will keyset-scan them: created_at ASC, message_id ASC — i.e.
  # message_id ASC here (canonical lowercase-hex uuid string order == Postgres uuid order).
  defp two_same_timestamp_messages do
    a = create!("A")
    b = create!("B")
    Repo.update_all(from(m in Message, where: m.message_id == ^a.message_id), set: [created_at: @shared_ts])
    Repo.update_all(from(m in Message, where: m.message_id == ^b.message_id), set: [created_at: @shared_ts])
    Enum.sort([a.message_id, b.message_id])
  end

  @tag :postgres_integration
  test "forward keyset walks same-timestamp rows one at a time without skipping" do
    [first_id, second_id] = two_same_timestamp_messages()

    # Page 1: forward from before both (same T, min uuid), limit 1 → the FIRST row; real cursor (full page).
    {:ok, page1} =
      Messages.list_messages(%{
        "conversation_id" => @conversation_id,
        "after_created_at" => DateTime.to_iso8601(@shared_ts),
        "after_id" => @min_uuid,
        "limit" => 1
      })

    assert [m1] = page1.messages
    assert m1.message_id == first_id
    assert page1.next_cursor.message_id == first_id

    # Page 2: continue from page1's cursor. THE PROOF — a bare-timestamp cursor (created_at > T) would
    # return [] and skip the second same-timestamp row; the compound keyset returns it.
    {:ok, page2} =
      Messages.list_messages(%{
        "conversation_id" => @conversation_id,
        "after_created_at" => page1.next_cursor.created_at,
        "after_id" => page1.next_cursor.message_id,
        "limit" => 1
      })

    assert [m2] = page2.messages
    assert m2.message_id == second_id

    # Page 3: nothing strictly after the last row → empty page + nil cursor (end of timeline).
    {:ok, page3} =
      Messages.list_messages(%{
        "conversation_id" => @conversation_id,
        "after_created_at" => page2.next_cursor.created_at,
        "after_id" => page2.next_cursor.message_id,
        "limit" => 1
      })

    assert page3.messages == []
    assert page3.next_cursor == nil
  end

  @tag :postgres_integration
  test "backward keyset returns the strictly-earlier same-timestamp row" do
    [first_id, second_id] = two_same_timestamp_messages()

    {:ok, page} =
      Messages.list_messages(%{
        "conversation_id" => @conversation_id,
        "before_created_at" => DateTime.to_iso8601(@shared_ts),
        "before_id" => second_id,
        "limit" => 10
      })

    assert [m] = page.messages
    assert m.message_id == first_id
  end

  @tag :postgres_integration
  test "no cursor params → unchanged recent page (newest first), cursor null when not full" do
    _older = create!("old")
    _newer = create!("new")

    {:ok, page} = Messages.list_messages(%{"conversation_id" => @conversation_id, "limit" => 10})

    assert Enum.map(page.messages, & &1.body) == ["new", "old"]
    assert page.next_cursor == nil
  end
end
