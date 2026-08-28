defmodule SharedInfra.ConversationBroadcastTest do
  @moduledoc """
  The `conversation_updated` fan-out itself: WHO gets a frame, whether it carries THEIR row, and when we stay
  silent. The endpoint is a fake that forwards each broadcast to the test process, so this needs no Phoenix
  and no DB — the per-user SQL it consumes is proven separately in ConversationService.InboxRowsTest.
  """
  use ExUnit.Case, async: false

  alias SharedInfra.ConversationBroadcast

  @conversation "11111111-1111-4111-8111-111111111111"
  @alice "22222222-2222-4222-8222-222222222222"
  @bob "33333333-3333-4333-8333-333333333333"

  defmodule FakeEndpoint do
    @moduledoc false
    def broadcast(topic, event, payload) do
      send(:conv_broadcast_test, {:broadcast, topic, event, payload})
      :ok
    end
  end

  defmodule ConvStub do
    @moduledoc false
    @behaviour SharedInfra.ConversationClient

    @alice "22222222-2222-4222-8222-222222222222"
    @bob "33333333-3333-4333-8333-333333333333"

    @impl true
    def get_conversation(_attrs),
      do: {:ok, %{participants: [%{user_id: @alice}, %{user_id: @bob}]}}

    # Alice has read everything (0); Bob has 2 waiting. Different rows for the same conversation.
    @impl true
    def inbox_rows(%{"user_ids" => user_ids}) do
      rows =
        Enum.map(user_ids, fn user_id ->
          %{
            user_id: user_id,
            conversation_id: "11111111-1111-4111-8111-111111111111",
            type: "group",
            title: "Launch",
            last_message_preview: "hello",
            last_message_kind: "text",
            unread_count: if(user_id == @alice, do: 0, else: 2),
            updated_at: "2026-07-14T10:00:00.000000Z",
            # A group row carries the avatar's media_id (the client renders from the presigned group_avatar_url);
            # the raw object_key must NEVER reach the wire frame (Android §8.6). Real rows no longer emit it, but
            # the frame builder must strip it regardless — this row includes it to prove the guard.
            group_avatar_media_id: "gm-1",
            group_avatar_object_key: "groups/secret/avatar.jpg",
            # Per-user inbox prefs ride the same row → the :pref (archive/pin) frame carries them to the client.
            pinned: true,
            archived: false
          }
        end)

      {:ok, %{rows: rows}}
    end
  end

  defmodule BrokenStub do
    @moduledoc false
    @behaviour SharedInfra.ConversationClient
    @impl true
    def get_conversation(_attrs), do: {:error, :conversation_unavailable}
    @impl true
    def inbox_rows(_attrs), do: raise("boom")
  end

  setup do
    Process.register(self(), :conv_broadcast_test)
    previous = Application.get_env(:shared_infra, :conversation_client_adapter)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shared_infra, :conversation_client_adapter, previous),
        else: Application.delete_env(:shared_infra, :conversation_client_adapter)
    end)

    :ok
  end

  test "fans out to EVERY participant, each frame carrying THAT user's own row" do
    ConversationBroadcast.broadcast_updated(FakeEndpoint, @conversation, @alice, :message)

    # Both went out, and each carries its OWN unread — not one shared number.
    frames = drain()
    assert length(frames) == 2
    assert %{"unread_count" => 0} = frame_for(frames, @alice)
    assert %{"unread_count" => 2} = frame_for(frames, @bob)
  end

  test "the wire frame drops the routing key and is string-keyed" do
    ConversationBroadcast.broadcast_updated(FakeEndpoint, @conversation, @alice, :message)

    assert_receive {:broadcast, _topic, "conversation_updated", payload}, 500
    refute Map.has_key?(payload, "user_id")
    refute Map.has_key?(payload, :user_id)
    assert payload["title"] == "Launch"
    assert payload["conversation_id"] == @conversation
  end

  test "the wire frame carries the per-user pinned/archived prefs (the :pref frame updates the client live)" do
    ConversationBroadcast.broadcast_updated(FakeEndpoint, @conversation, @alice, :pref,
      only: [@alice]
    )

    assert_receive {:broadcast, "user:" <> _, "conversation_updated", payload}, 500
    assert payload["pinned"] == true
    assert payload["archived"] == false
  end

  test "the wire frame NEVER carries the raw group-avatar object key (Android §8.6 — clients see the url)" do
    ConversationBroadcast.broadcast_updated(FakeEndpoint, @conversation, @alice, :message)

    assert_receive {:broadcast, _topic, "conversation_updated", payload}, 500
    # The raw object-store path must not leak on the wire, in either key form.
    refute Map.has_key?(payload, "group_avatar_object_key")
    refute Map.has_key?(payload, :group_avatar_object_key)

    # media_id is an opaque id (not a storage path) and rides along; the object key is the only leak.
    assert payload["group_avatar_media_id"] == "gm-1"
  end

  test ":only limits the fan-out to the changed user (the receipt trigger — no waking all N inboxes)" do
    ConversationBroadcast.broadcast_updated(FakeEndpoint, @conversation, @bob, :receipt,
      only: [@bob]
    )

    assert_receive {:broadcast, topic, "conversation_updated", _}, 500
    assert topic == "user:#{@bob}"
    # Alice's inbox is NOT woken — her count didn't change.
    refute_receive {:broadcast, _, _, _}, 200
  end

  test "skip_if_unread SUPPRESSES the frame when the count did not move (a re-read of a read message)" do
    # Bob's current count is 2, and it was 2 before the mark_read → nothing changed → say nothing.
    ConversationBroadcast.broadcast_updated(FakeEndpoint, @conversation, @bob, :receipt,
      only: [@bob],
      skip_if_unread: 2
    )

    refute_receive {:broadcast, _, _, _}, 300
  end

  test "skip_if_unread still SENDS when the count actually moved" do
    # Was 5 before the read, is 2 now → a real change → the reader's badge must update.
    ConversationBroadcast.broadcast_updated(FakeEndpoint, @conversation, @bob, :receipt,
      only: [@bob],
      skip_if_unread: 5
    )

    assert_receive {:broadcast, topic, "conversation_updated", %{"unread_count" => 2}}, 500
    assert topic == "user:#{@bob}"
  end

  test "a REMOVED member gets a final `removed` frame; the remaining members get normal rows" do
    ConversationBroadcast.broadcast_updated(FakeEndpoint, @conversation, @alice, :participant,
      removed_user_id: "99999999-9999-4999-8999-999999999999"
    )

    assert_receive {:broadcast, "user:99999999-9999-4999-8999-999999999999",
                    "conversation_updated",
                    %{"removed" => true, "conversation_id" => @conversation}},
                   500

    # …and the remaining participants still get their live rows (the stub's participant list).
    frames = drain()
    assert frame_for(frames, @alice)
    assert frame_for(frames, @bob)
  end

  test "unread_before reads the caller's CURRENT count (the pre-mark_read snapshot)" do
    assert ConversationBroadcast.unread_before(@conversation, @bob) == 2
    assert ConversationBroadcast.unread_before(@conversation, @alice) == 0
  end

  test "a broken client NEVER crashes the caller and NEVER emits a frame (fire-and-forget)" do
    Application.put_env(:shared_infra, :conversation_client_adapter, BrokenStub)

    # The raise happens inside the Task; the caller gets :ok regardless — a broadcast failure must never fail
    # the primary action (the message send / read / rename that triggered it).
    assert :ok =
             ConversationBroadcast.broadcast_updated(
               FakeEndpoint,
               @conversation,
               @alice,
               :message
             )

    refute_receive {:broadcast, _, _, _}, 300

    # unread_before degrades to nil ("don't skip") rather than blowing up the request path.
    assert ConversationBroadcast.unread_before(@conversation, @alice) == nil
  end

  # --- the post-write floor: the frame must never be one message behind -----------------------------
  #
  # ConvStub's row is deliberately FROZEN at 2026-07-14T10:00:00 — it stands in for the real defect:
  # `conversations.last_message_at` is denormalised and, under the Scylla store, written by the Kafka
  # projection AFTER the send returns, so this fan-out re-reads the PREVIOUS message's timestamp.

  @stale_row_updated_at "2026-07-14T10:00:00.000000Z"

  test "a :message frame carries the COMMITTED message's timestamp, not the unprojected row's" do
    committed_at = "2026-07-14T10:05:31.204118Z"

    ConversationBroadcast.broadcast_updated(FakeEndpoint, @conversation, @alice, :message,
      message: text_message(committed_at)
    )

    frames = drain()

    # EVERY participant's frame, not just the sender's — inbox ordering broke for all of them.
    for user <- [@alice, @bob] do
      assert frame_for(frames, user)["updated_at"] == committed_at
    end
  end

  test "a DateTime created_at is formatted exactly like the row's to_char output" do
    {:ok, committed_at, _} = DateTime.from_iso8601("2026-07-14T10:05:31.204118Z")

    ConversationBroadcast.broadcast_updated(FakeEndpoint, @conversation, @alice, :message,
      message: text_message(committed_at)
    )

    assert frame_for(drain(), @alice)["updated_at"] == "2026-07-14T10:05:31.204118Z"
  end

  test "sub-second precision is padded to six digits, like every other row on the wire" do
    # A timestamp that survived a fraction-less or millisecond ISO round-trip must not reach clients as
    # ".0Z" or ".204Z" — the field's shape is part of the contract.
    for {given, expected} <- [
          {"2026-07-14T10:05:31Z", "2026-07-14T10:05:31.000000Z"},
          {"2026-07-14T10:05:31.204Z", "2026-07-14T10:05:31.204000Z"}
        ] do
      ConversationBroadcast.broadcast_updated(FakeEndpoint, @conversation, @alice, :message,
        message: text_message(given)
      )

      assert frame_for(drain(), @alice)["updated_at"] == expected
    end
  end

  test "it is a FLOOR, not an overwrite: a row NEWER than the message is left alone" do
    # The projection landed (or another message raced in) between the write and this read. The row is
    # already correct and must not be dragged backwards to our own message's stamp.
    ConversationBroadcast.broadcast_updated(FakeEndpoint, @conversation, @alice, :message,
      message: text_message("2026-07-14T09:00:00.000000Z")
    )

    assert frame_for(drain(), @alice)["updated_at"] == @stale_row_updated_at
  end

  test "an equal created_at changes nothing (the projection already landed)" do
    ConversationBroadcast.broadcast_updated(FakeEndpoint, @conversation, @alice, :message,
      message: text_message(@stale_row_updated_at)
    )

    assert frame_for(drain(), @alice)["updated_at"] == @stale_row_updated_at
  end

  test "the non-message triggers pass no :message and are untouched" do
    for trigger <- [:receipt, :title, :participant, :pref] do
      ConversationBroadcast.broadcast_updated(FakeEndpoint, @conversation, @alice, trigger)
      assert frame_for(drain(), @alice)["updated_at"] == @stale_row_updated_at
    end
  end

  test "an unparseable or missing created_at degrades to the row's own value, never to nil" do
    for bad <- [nil, "", "not-a-timestamp", 12_345] do
      ConversationBroadcast.broadcast_updated(FakeEndpoint, @conversation, @alice, :message,
        message: text_message(bad)
      )

      assert frame_for(drain(), @alice)["updated_at"] == @stale_row_updated_at
    end
  end

  test "the override does not disturb the rest of the row, including the object-key guard" do
    frame =
      ConversationBroadcast.broadcast_updated(FakeEndpoint, @conversation, @alice, :message,
        message: text_message("2026-07-14T10:05:31.204118Z")
      )
      |> then(fn :ok -> drain() end)
      |> frame_for(@bob)

    assert frame["unread_count"] == 2

    # The preview now comes from the TRIGGERING message ("fresh"), not the unprojected row ("hello") —
    # that is the defect this slice fixes. Everything the message does not speak for is passed through.
    assert frame["last_message_preview"] == "fresh"
    assert frame["group_avatar_media_id"] == "gm-1"
    refute Map.has_key?(frame, "group_avatar_object_key")
    refute Map.has_key?(frame, "user_id")
    # Exactly one updated_at key, in the wire's string style — never both shapes.
    assert Enum.count(frame, fn {k, _} -> to_string(k) == "updated_at" end) == 1
  end

  # --- preview + kind composed from the triggering message ------------------------------------------
  #
  # Same defect as the timestamp, same shape: `last_message_body/type/content_type` are the SAME
  # unprojected denormalised columns, so the row ConvStub returns describes the PREVIOUS message
  # ("hello"). The frame must describe the one that triggered it.

  @committed_at "2026-07-14T10:05:31.204118Z"

  defp broadcast!(message) do
    ConversationBroadcast.broadcast_updated(FakeEndpoint, @conversation, @alice, :message,
      message: message
    )

    frame_for(drain(), @alice)
  end

  test "a TEXT message's own body and kind are what the frame carries" do
    frame =
      broadcast!(%{
        "message_type" => "text",
        "body" => "the message that triggered this",
        "created_at" => @committed_at
      })

    assert frame["last_message_preview"] == "the message that triggered this"
    assert frame["last_message_kind"] == "text"
    # And it stays consistent with the timestamp — one message describes all three fields.
    assert frame["updated_at"] == @committed_at
  end

  test "a MEDIA message yields no preview text and a kind resolved from metadata.content_type" do
    for {content_type, kind} <- [
          {"image/png", "image"},
          {"video/mp4", "video"},
          {"audio/ogg", "audio"},
          {"application/pdf", "file"}
        ] do
      frame =
        broadcast!(%{
          "message_type" => "media",
          "body" => "photo.png",
          "metadata" => %{"content_type" => content_type},
          "created_at" => @committed_at
        })

      assert frame["last_message_preview"] == nil
      assert frame["last_message_kind"] == kind
    end
  end

  test "a CALL message surfaces its short human body, matching the in-thread entry" do
    frame =
      broadcast!(%{
        "message_type" => "call",
        "body" => "Missed voice call",
        "created_at" => @committed_at
      })

    assert frame["last_message_preview"] == "Missed voice call"
    assert frame["last_message_kind"] == "call"
  end

  # --- 108: THE SEALED GATE ON THE WIRE ---

  test "a SEALED message NEVER puts content on the wire — kind only, no preview" do
    frame =
      broadcast!(%{
        "message_type" => "sealed",
        "metadata" => %{"envelopes" => [%{"device_id" => "d1", "ciphertext" => "AA=="}]},
        "created_at" => @committed_at
      })

    assert frame["last_message_preview"] == nil
    # The kind is what the client keys its own locally-decrypted preview off (Android vc20/vc27).
    assert frame["last_message_kind"] == "sealed"
    assert frame["updated_at"] == @committed_at
  end

  test "even a sealed message carrying a body cannot leak it" do
    # Messages.create_message rejects this shape, but the gate must not DEPEND on that: it is the clause
    # order in InboxPreview, so a body attached by any route still yields nil.
    for body <- ["the actual plaintext", "🔒 Message"] do
      frame =
        broadcast!(%{"message_type" => "sealed", "body" => body, "created_at" => @committed_at})

      assert frame["last_message_preview"] == nil
      refute frame["last_message_preview"] == body
    end
  end

  # --- the projection landing afterwards changes nothing ---

  test "a row the projection HAS reached is left entirely alone — same values, no double-apply" do
    # The row already describes our message (its timestamp is not older), so nothing is overridden and the
    # frame is what the projected row says. This is what makes the fix a no-op once Kafka catches up.
    frame =
      broadcast!(%{
        "message_type" => "text",
        "body" => "fresh",
        "created_at" => "2026-07-14T09:59:59.000000Z"
      })

    assert frame["updated_at"] == @stale_row_updated_at
    assert frame["last_message_preview"] == "hello"
    assert frame["last_message_kind"] == "text"
  end

  test "a message we cannot date leaves preview and kind alone too — all three move together" do
    frame = broadcast!(%{"message_type" => "sealed", "body" => nil, "created_at" => nil})

    assert frame["updated_at"] == @stale_row_updated_at
    assert frame["last_message_preview"] == "hello"
    assert frame["last_message_kind"] == "text"
  end

  # A committed TEXT message, the shape the create paths hand the fan-out. Body "fresh" is deliberately
  # different from ConvStub's row preview ("hello"), so a frame composed from the unprojected row shows up
  # in these tests too, not only in the dedicated preview ones below.
  defp text_message(created_at) do
    %{"message_type" => "text", "body" => "fresh", "created_at" => created_at}
  end

  # --- helpers ---

  # The fan-out runs in a Task, so wait generously for the FIRST frame, then sweep up whatever else landed.
  defp drain(acc \\ [], timeout \\ 700) do
    receive do
      {:broadcast, topic, event, payload} -> drain([{topic, event, payload} | acc], 150)
    after
      timeout -> acc
    end
  end

  defp frame_for(frames, user_id) do
    Enum.find_value(frames, fn {topic, _event, payload} ->
      if topic == "user:#{user_id}", do: payload
    end)
  end
end
