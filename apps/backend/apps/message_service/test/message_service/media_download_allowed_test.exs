defmodule MessageService.MediaDownloadAllowedTest do
  @moduledoc """
  The owner-anchored EXISTS on real SQL (`@tag :postgres_integration`). Proves: THE BROADCAST CASE (one
  asset fanned by the owner into three DMs — all three recipients allowed, an uninvolved fourth denied);
  THE FORWARD-BY-OWNER CASE (the owner re-sends into a conversation the original recipient isn't in —
  the new recipient allowed, the original keeps access via their own conversation); THE LEAK CASE on
  actual rows (message-create really does accept a non-owner referencing someone else's media_id — the
  planted row EXISTS and still grants nobody anything, because it fails the sender=owner anchor);
  left_at is a live deny; unsent → false; a DELETED message still authorizes (no liveness filter —
  preserving get_by_media_id's "authorization is by membership, not message liveness" reasoning: bytes a
  recipient legitimately received don't vanish on delete-for-everyone); and the QUERY COUNT — exactly 1,
  regardless of how many messages reference the media.
  """
  use MessageService.DataCase, async: false

  alias MessageService.{Messages, MessageStore}

  @owner "11111111-1111-4111-8111-111111111111"
  @bob "22222222-2222-4222-8222-222222222222"
  @carol "33333333-3333-4333-8333-333333333333"
  @dave "44444444-4444-4444-8444-444444444444"
  @uninvolved "55555555-5555-4555-8555-555555555555"

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

  defp conversation!(members) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, type, created_by, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, 'direct', $2::text::uuid, 'active', now(), now())",
      [id, hd(members)]
    )

    for m <- members do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
        [id, m]
      )
    end

    id
  end

  # A media message through the REAL create path (which — the verified finding — checks only presence,
  # never ownership of media_id).
  defp send_media!(conversation_id, sender, media_id) do
    {:ok, message} =
      Messages.create_message(%{
        "conversation_id" => conversation_id,
        "sender_user_id" => sender,
        "message_type" => "media",
        "media_id" => media_id
      })

    message
  end

  defp allowed?(media_id, owner, viewer) do
    {:ok, %{allowed: allowed}} =
      MessageStore.media_download_allowed(%{
        "media_id" => media_id,
        "owner_user_id" => owner,
        "viewer_user_id" => viewer
      })

    allowed
  end

  @tag :postgres_integration
  test "BROADCAST: one asset fanned into three DMs — all three recipients allowed, the fourth denied" do
    Enum.each([@owner, @bob, @carol, @dave, @uninvolved], &user!/1)
    media = Ecto.UUID.generate()

    for recipient <- [@bob, @carol, @dave] do
      dm = conversation!([@owner, recipient])
      send_media!(dm, @owner, media)
    end

    assert allowed?(media, @owner, @bob)
    assert allowed?(media, @owner, @carol)
    assert allowed?(media, @owner, @dave)
    refute allowed?(media, @owner, @uninvolved)
  end

  @tag :postgres_integration
  test "FORWARD-BY-OWNER: the new recipient gains access, the original keeps it, the uninvolved never has it" do
    Enum.each([@owner, @bob, @carol, @uninvolved], &user!/1)
    media = Ecto.UUID.generate()

    source = conversation!([@owner, @bob])
    send_media!(source, @owner, media)

    # Carol is NOT in the source conversation; the owner forwards into owner↔carol reusing the id.
    target = conversation!([@owner, @carol])
    send_media!(target, @owner, media)

    assert allowed?(media, @owner, @carol)
    assert allowed?(media, @owner, @bob)
    refute allowed?(media, @owner, @uninvolved)
  end

  @tag :postgres_integration
  test "THE LEAK CASE: create ACCEPTS bob planting the owner's media_id into bob↔carol — and it grants nothing" do
    Enum.each([@owner, @bob, @carol], &user!/1)
    media = Ecto.UUID.generate()

    dm = conversation!([@owner, @bob])
    send_media!(dm, @owner, media)

    # The verified finding: the create path does NOT validate media ownership — bob's planted
    # reference is ACCEPTED as a message (so the deny below is authz, not create).
    planted_dm = conversation!([@bob, @carol])
    planted = send_media!(planted_dm, @bob, media)
    assert planted.media_id == media

    # Carol sits in a conversation REFERENCING the media — but not one where the OWNER sent it.
    refute allowed?(media, @owner, @carol)

    # And bob's plant did not expand bob's own standing either (he was already allowed via the real DM).
    assert allowed?(media, @owner, @bob)
  end

  @tag :postgres_integration
  test "left_at is a LIVE deny; unsent is owner-only-by-absence; a DELETED message still authorizes" do
    Enum.each([@owner, @bob], &user!/1)
    media = Ecto.UUID.generate()
    dm = conversation!([@owner, @bob])
    message = send_media!(dm, @owner, media)

    assert allowed?(media, @owner, @bob)

    # Bob is removed → the active-membership probe fails live.
    Repo.query!(
      "UPDATE conversation_participants SET left_at = now(), left_reason = 'removed' " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [dm, @bob]
    )

    refute allowed?(media, @owner, @bob)

    Repo.query!(
      "UPDATE conversation_participants SET left_at = NULL, left_reason = NULL " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [dm, @bob]
    )

    # DELETED message: DELIBERATELY still authorizes (no liveness filter — membership, not message
    # liveness, is the rule; preserved from get_by_media_id's reasoning).
    Repo.query!(
      "UPDATE messages SET deleted_at = now(), status = 'deleted' WHERE message_id = $1::text::uuid",
      [message.message_id]
    )

    assert allowed?(media, @owner, @bob)

    # Unsent: no qualifying message at all → false (the gateway's owner fast-path handles the owner).
    unsent = Ecto.UUID.generate()
    refute allowed?(unsent, @owner, @bob)
  end

  @tag :postgres_integration
  test "QUERY COUNT: exactly ONE query, however many messages reference the media (no scan-per-message)" do
    Enum.each([@owner, @uninvolved], &user!/1)
    media = Ecto.UUID.generate()

    # 12 conversations all carrying the owner's sends of the same asset.
    for _ <- 1..12 do
      recipient = Ecto.UUID.generate()
      user!(recipient)
      dm = conversation!([@owner, recipient])
      send_media!(dm, @owner, media)
    end

    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:message_service, :repo, :query],
      fn _e, _m, _meta, _c -> send(parent, {:q, ref}) end,
      nil
    )

    refute allowed?(media, @owner, @uninvolved)
    :telemetry.detach({__MODULE__, ref})

    count =
      Enum.reduce_while(1..100, 0, fn _i, acc ->
        receive do
          {:q, ^ref} -> {:cont, acc + 1}
        after
          0 -> {:halt, acc}
        end
      end)

    assert count == 1
  end

  # THE REGRESSION THIS FILE EXISTS FOR. A `$N::uuid` cast against a STRING param raises
  # DBConnection.EncodeError; the old blanket `rescue _ -> {:ok, %{allowed: false}}` turned that into a
  # plain "denied", so every inbound media download 403'd for days with NOTHING in the logs — own photos
  # rendered (the gateway's owner fast-path skips this oracle), everyone else's showed "Tap to retry".
  # Fail-closed is still right; failing SILENTLY is not. A broken oracle must be loud.
  @tag :postgres_integration
  test "a BROKEN oracle still denies, but LOGS at error level (it is a fault, not a decision)" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        # Not a uuid → Postgres rejects the ::uuid cast → the query raises inside the rescue.
        assert {:ok, %{allowed: false}} =
                 MessageStore.PostgresAdapter.media_download_allowed(%{
                   "media_id" => "definitely-not-a-uuid",
                   "owner_user_id" => @owner,
                   "viewer_user_id" => @bob
                 })
      end)

    assert log =~ "media_download_allowed FAILED"
    assert log =~ "[error]"
  end

  # The complement: a MISSING identifier is a genuine authorization miss, not a fault — deny quietly.
  @tag :postgres_integration
  test "a missing identifier denies WITHOUT logging (that path is a decision, not a fault)" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{allowed: false}} =
                 MessageStore.PostgresAdapter.media_download_allowed(%{
                   "media_id" => "",
                   "owner_user_id" => @owner,
                   "viewer_user_id" => @bob
                 })
      end)

    refute log =~ "media_download_allowed FAILED"
  end
end
