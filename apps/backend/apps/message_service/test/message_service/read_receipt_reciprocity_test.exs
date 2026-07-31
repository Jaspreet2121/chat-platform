defmodule MessageService.ReadReceiptReciprocityTest do
  @moduledoc """
  read_by_count reciprocity on the LOAD path (`@tag :postgres_integration` — the filter is SQL, on the real
  PostgresAdapter): a reader who DISABLED read receipts is EXCLUDED from read_by_count (reader half); a VIEWER
  who disabled sees read_by_count 0 for every message (viewer half). delivered_by_count is never affected.
  Both halves resolve in ONE extra query for the whole page (the reader half is a JOIN inside receipt_counts;
  the viewer half is a single per-page lookup) — no N+1.
  """
  use MessageService.DataCase, async: false

  alias MessageService.{Messages, MessageStore, Receipts}

  @conv "11111111-1111-4111-8111-111111111111"
  @sender "22222222-2222-4222-8222-222222222222"
  @reader_on "33333333-3333-4333-8333-333333333333"
  @reader_off "44444444-4444-4444-8444-444444444444"
  @viewer_off "55555555-5555-4555-8555-555555555555"

  setup do
    prev = %{
      persistence: Application.get_env(:message_service, :message_persistence, false),
      adapter:
        Application.get_env(
          :message_service,
          :message_store_adapter,
          MessageStore.QueryPlanAdapter
        )
    }

    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:message_service, :message_store_adapter, MessageStore.PostgresAdapter)

    on_exit(fn ->
      Application.put_env(:message_service, :message_persistence, prev.persistence)
      Application.put_env(:message_service, :message_store_adapter, prev.adapter)
    end)

    seed_conversation!()
    :ok
  end

  # REQUIRED since messages became tenant-anchored: put_message/1 resolves the conversation's
  # AUTHORITATIVE app_id and stamps it on the row, so a message whose conversation does not exist is
  # rejected with :message_invalid rather than landing under the tenant-zero default. This suite
  # predates that change and seeded no conversation, which is why it could never pass against a real
  # database — nothing ran it.
  defp participants, do: [@sender, @reader_on, @reader_off, @viewer_off]

  defp seed_conversation! do
    for {user, i} <- Enum.with_index(participants()) do
      Repo.query!(
        "INSERT INTO users_auth (id, phone_number) VALUES ($1::text::uuid, $2) ON CONFLICT DO NOTHING",
        [user, "+9112345#{100_000 + i}"]
      )
    end

    Repo.query!(
      "INSERT INTO conversations (id, type, created_by) " <>
        "VALUES ($1::text::uuid, 'group', $2::text::uuid) ON CONFLICT DO NOTHING",
      [@conv, @sender]
    )

    for user <- participants() do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id) " <>
          "VALUES ($1::text::uuid, $2::text::uuid) ON CONFLICT DO NOTHING",
        [@conv, user]
      )
    end
  end

  defp user!(id) do
    Repo.query!(
      "INSERT INTO users_auth (id, email, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2, 'x', now(), now()) ON CONFLICT DO NOTHING",
      [id, "#{id}@test.local"]
    )
  end

  defp privacy!(user_id, read_receipts_enabled) do
    Repo.query!(
      "INSERT INTO user_privacy_settings " <>
        "(user_id, last_seen_visibility, profile_photo_visibility, read_receipts_enabled, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, 'contacts', 'contacts', $2, now(), now())",
      [user_id, read_receipts_enabled]
    )
  end

  defp send_message! do
    {:ok, created} =
      Messages.create_message(%{
        "conversation_id" => @conv,
        "sender_user_id" => @sender,
        "message_type" => "text",
        "body" => "hi"
      })

    created.message_id
  end

  defp read_by_count(mid, viewer) do
    {:ok, timeline} =
      Messages.list_messages(%{"conversation_id" => @conv, "viewer_user_id" => viewer})

    Enum.find(timeline.messages, &(&1.message_id == mid)).read_by_count
  end

  @tag :postgres_integration
  test "read_by_count excludes a reader who disabled receipts; a disabled VIEWER sees 0" do
    Enum.each([@sender, @reader_on, @reader_off, @viewer_off], &user!/1)
    privacy!(@reader_off, false)
    privacy!(@viewer_off, false)
    # @reader_on has no privacy row → default enabled.

    mid = send_message!()

    Receipts.mark_read(%{
      "conversation_id" => @conv,
      "message_id" => mid,
      "user_id" => @reader_on
    })

    Receipts.mark_read(%{
      "conversation_id" => @conv,
      "message_id" => mid,
      "user_id" => @reader_off
    })

    # A viewer with receipts ON counts ONLY reader_on — the disabled reader is excluded (reader half).
    assert read_by_count(mid, @sender) == 1

    # A viewer who disabled receipts sees no read ticks at all (viewer half).
    assert read_by_count(mid, @viewer_off) == 0
  end

  @tag :postgres_integration
  test "delivered_by_count is NOT affected by the reader's read_receipts_enabled" do
    Enum.each([@sender, @reader_off], &user!/1)
    privacy!(@reader_off, false)

    mid = send_message!()

    Receipts.mark_delivered(%{
      "conversation_id" => @conv,
      "message_id" => mid,
      "user_id" => @reader_off
    })

    {:ok, timeline} =
      Messages.list_messages(%{"conversation_id" => @conv, "viewer_user_id" => @sender})

    msg = Enum.find(timeline.messages, &(&1.message_id == mid))
    # The disabled reader still counts toward delivered (single tick unaffected)…
    assert msg.delivered_by_count == 1
    # …but not toward read.
    assert msg.read_by_count == 0
  end
end
