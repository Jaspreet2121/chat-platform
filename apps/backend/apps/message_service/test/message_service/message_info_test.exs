defmodule MessageService.MessageInfoTest do
  @moduledoc """
  Message info (`@tag :postgres_integration` — the privacy predicate is SQL, on the real PostgresAdapter).
  Proves: the read/delivered split; the reader half (a receipts-off reader is ABSENT from read, PRESENT in
  delivered) asserted IN THE SAME RUN as read_by_count so the shared `read_receipts_on` predicate can't
  drift; the viewer half (a sender who disabled receipts gets read: [] + read_hidden: true, delivered
  intact); sender-only + tombstone + unknown-message gates; a read-without-delivered row proving receipt
  via read_at; and the bounded query count (3 queries — message, receipts, viewer privacy — REGARDLESS of
  receipt count). Fixtures mirror ReadReceiptReciprocityTest.
  """
  use MessageService.DataCase, async: false

  alias MessageService.{Messages, MessageStore, Receipts}

  @conv "11111111-1111-4111-8111-111111111111"
  @sender "22222222-2222-4222-8222-222222222222"
  @reader_on "33333333-3333-4333-8333-333333333333"
  @reader_off "44444444-4444-4444-8444-444444444444"
  @delivered_only "55555555-5555-4555-8555-555555555555"

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

    :ok
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

  defp info(mid, viewer \\ @sender),
    do:
      Messages.message_info(%{
        "conversation_id" => @conv,
        "message_id" => mid,
        "viewer_user_id" => viewer
      })

  defp ids(entries), do: Enum.map(entries, & &1.user_id)

  @tag :postgres_integration
  test "read/delivered split + the SHARED predicate can't drift from read_by_count (same-run assert)" do
    Enum.each([@sender, @reader_on, @reader_off, @delivered_only], &user!/1)
    privacy!(@reader_off, false)

    mid = send_message!()

    Receipts.mark_delivered(%{
      "conversation_id" => @conv,
      "message_id" => mid,
      "user_id" => @reader_on
    })

    Receipts.mark_read(%{
      "conversation_id" => @conv,
      "message_id" => mid,
      "user_id" => @reader_on
    })

    # reader_off READ it too — but disabled receipts (no prior delivered receipt: read_at proves receipt).
    Receipts.mark_read(%{
      "conversation_id" => @conv,
      "message_id" => mid,
      "user_id" => @reader_off
    })

    Receipts.mark_delivered(%{
      "conversation_id" => @conv,
      "message_id" => mid,
      "user_id" => @delivered_only
    })

    assert {:ok, result} = info(mid)

    # READ: only the receipts-on reader. The receipts-off reader is ABSENT (reader half)…
    assert ids(result.read) == [@reader_on]
    assert [%{user_id: @reader_on, read_at: %DateTime{}}] = result.read
    refute result.read_hidden

    # …and PRESENT in delivered (WhatsApp's 'stuck on Delivered'), timestamp degraded to their read_at,
    # alongside the genuinely delivered-only member.
    assert Enum.sort(ids(result.delivered)) == Enum.sort([@reader_off, @delivered_only])
    assert Enum.all?(result.delivered, &match?(%DateTime{}, &1.delivered_at))

    # THE DRIFT GUARD: in the SAME run, read_by_count counts exactly the read list (both consume
    # read_receipts_on — one predicate, two call sites).
    {:ok, timeline} =
      Messages.list_messages(%{"conversation_id" => @conv, "viewer_user_id" => @sender})

    assert Enum.find(timeline.messages, &(&1.message_id == mid)).read_by_count ==
             length(result.read)
  end

  @tag :postgres_integration
  test "VIEWER half: a sender who disabled receipts gets read: [] + read_hidden, delivered intact" do
    Enum.each([@sender, @reader_on], &user!/1)
    privacy!(@sender, false)

    mid = send_message!()

    Receipts.mark_delivered(%{
      "conversation_id" => @conv,
      "message_id" => mid,
      "user_id" => @reader_on
    })

    Receipts.mark_read(%{
      "conversation_id" => @conv,
      "message_id" => mid,
      "user_id" => @reader_on
    })

    assert {:ok, result} = info(mid)

    # No read state for a sender who turned receipts off — but the reader doesn't vanish: they show as
    # delivered. read_hidden tells the client "YOUR setting hides this", not "nobody read it".
    assert result.read == []
    assert result.read_hidden == true
    assert ids(result.delivered) == [@reader_on]
  end

  @tag :postgres_integration
  test "sender-only: a non-sender viewer → :not_sender; unknown + TOMBSTONED message → :message_not_found" do
    Enum.each([@sender, @reader_on], &user!/1)
    mid = send_message!()

    assert {:error, :not_sender} = info(mid, @reader_on)
    assert {:error, :message_not_found} = info(Ecto.UUID.generate())

    # Tombstone (delete-for-everyone): the info screen dies with the message — 404, not a 500.
    {:ok, _} =
      Messages.delete_message(%{
        "conversation_id" => @conv,
        "message_id" => mid,
        "actor_user_id" => @sender
      })

    assert {:error, :message_not_found} = info(mid)
  end

  @tag :postgres_integration
  test "a message nobody has touched: both lists empty (direct-chat shape is the same, just ≤1 entries)" do
    user!(@sender)
    mid = send_message!()

    assert {:ok, %{read: [], delivered: [], read_hidden: false}} = info(mid)
  end

  @tag :postgres_integration
  test "BOUNDED: 3 queries (message + receipts + viewer privacy) regardless of receipt count" do
    user!(@sender)
    mid = send_message!()

    for n <- 1..30 do
      uid = Ecto.UUID.generate()
      user!(uid)
      op = if rem(n, 2) == 0, do: &Receipts.mark_read/1, else: &Receipts.mark_delivered/1
      op.(%{"conversation_id" => @conv, "message_id" => mid, "user_id" => uid})
    end

    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:message_service, :repo, :query],
      fn _event, _measurements, _meta, _config -> send(parent, {:query, ref}) end,
      nil
    )

    assert {:ok, result} = info(mid)
    :telemetry.detach({__MODULE__, ref})

    assert length(result.read) + length(result.delivered) == 30

    count =
      Enum.reduce_while(1..1000, 0, fn _i, acc ->
        receive do
          {:query, ^ref} -> {:cont, acc + 1}
        after
          0 -> {:halt, acc}
        end
      end)

    # message fetch + ONE receipts query + ONE viewer-privacy lookup — never O(receipts).
    assert count == 3
  end
end
