defmodule MessageService.ScyllaMediaOracleTest do
  @moduledoc """
  THE ORACLE'S BATTERY (`@tag :scylla_integration`) — plus the other five of C4's six, live against
  both engines. media_download_allowed is the query that, broken, silently denied every incoming
  media download for days and looked like a client bug the whole time; its port must preserve the
  owner-anchored rule EXACTLY: viewer is owner (gateway fast-path, not here), OR viewer is an ACTIVE
  member of ANY conversation containing a message referencing this media whose SENDER IS THE OWNER.

  The battery: BROADCAST (the case the rule exists for), PLANTED REFERENCE (the sender==owner filter
  is the leak defense — mutation-checked during development: removing the filter turns this red),
  left_at LIVE-DENY (membership is Postgres-live, so departure bites even though the projection still
  names the conversation), and PROJECTION ABSENT (deny AND log loudly — the silent version of this
  exact denial is what cost days).

  message_info holds reciprocity to the Postgres suite's own expectations (receipts-off reader:
  absent from read, present in delivered; receipts-off viewer: read [] + read_hidden, delivered
  intact). Polls prove the (iii) classification against the metadata-JSON convention.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MessageService.MessageStore.ScyllaAdapter
  alias SharedInfra.Scylla.XandraAdapter

  @moduletag :scylla_integration

  @cluster SharedInfra.Scylla.XandraAdapter.Cluster
  @gregorian_offset 0x01B21DD213814000
  @tenant_zero "00000000-0000-0000-0000-000000000001"

  setup_all do
    nodes =
      System.get_env("SCYLLA_TEST_NODES", "localhost:9042") |> String.split(",", trim: true)

    ensure_no_cluster()
    {:ok, _pid} = XandraAdapter.start_link(nodes: nodes, keyspace: "chat_messages")
    Process.sleep(2_000)

    previous = Application.get_env(:message_service, :scylla_client_adapter)
    Application.put_env(:message_service, :scylla_client_adapter, XandraAdapter)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:message_service, :scylla_client_adapter, previous),
        else: Application.delete_env(:message_service, :scylla_client_adapter)

      ensure_no_cluster()
    end)

    :ok
  end

  setup do
    case MessageService.Repo.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MessageService.Repo)
    :ok
  end

  defp ensure_no_cluster do
    case Process.whereis(@cluster) do
      nil -> :ok
      pid -> Supervisor.stop(pid, :normal, 5_000)
    end

    wait_unregistered(50)
  catch
    :exit, _ -> wait_unregistered(50)
  end

  defp wait_unregistered(0), do: :ok

  defp wait_unregistered(tries) do
    case Process.whereis(@cluster) do
      nil -> :ok
      _ -> Process.sleep(20) && wait_unregistered(tries - 1)
    end
  end

  defp timeuuid_at(%DateTime{} = dt) do
    timestamp = DateTime.to_unix(dt, :microsecond) * 10 + @gregorian_offset

    time_low = Bitwise.band(timestamp, 0xFFFF_FFFF)
    time_mid = timestamp |> Bitwise.bsr(32) |> Bitwise.band(0xFFFF)
    time_hi = timestamp |> Bitwise.bsr(48) |> Bitwise.band(0x0FFF) |> Bitwise.bor(0x1000)

    <<clock_seq::16, node::48>> = :crypto.strong_rand_bytes(8)
    clock_seq = clock_seq |> Bitwise.band(0x3FFF) |> Bitwise.bor(0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [
      time_low,
      time_mid,
      time_hi,
      clock_seq,
      node
    ])
    |> IO.iodata_to_binary()
  end

  # --- Postgres fixtures (membership is the live half of the oracle) -------------------------------

  defp pg!(sql, params), do: MessageService.Repo.query!(sql, params)

  defp user! do
    id = Ecto.UUID.generate()

    pg!(
      "INSERT INTO users_auth (id, app_id, email, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', now(), now())",
      [id, @tenant_zero, "#{id}@test.local"]
    )

    id
  end

  defp conversation!(members) do
    id = Ecto.UUID.generate()

    pg!(
      "INSERT INTO conversations (id, app_id, type, created_by, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid, 'active', now(), now())",
      [id, @tenant_zero, hd(members)]
    )

    for u <- members do
      pg!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
        [id, u]
      )
    end

    id
  end

  defp put!(conversation_id, sender, overrides \\ %{}) do
    at = Map.get(overrides, "created_at", DateTime.utc_now())

    attrs =
      Map.merge(
        %{
          "conversation_id" => conversation_id,
          "bucket_date" => at |> DateTime.to_date() |> Date.to_iso8601(),
          "message_id" => timeuuid_at(at),
          "sender_user_id" => sender,
          "message_type" => "text",
          "body" => "hello",
          "media_id" => nil,
          "reply_to_message_id" => nil,
          "status" => "active",
          "metadata" => %{},
          "created_at" => at,
          "edited_at" => nil,
          "deleted_at" => nil
        },
        overrides
      )

    {:ok, _} = ScyllaAdapter.put_message(attrs)
    attrs["message_id"]
  end

  defp media!(conversation_id, sender, media_id, at \\ nil) do
    at = at || DateTime.utc_now()

    put!(conversation_id, sender, %{
      "created_at" => at,
      "message_type" => "media",
      "body" => nil,
      "media_id" => media_id,
      "metadata" => %{"content_type" => "image/png", "media_id" => media_id}
    })
  end

  defp allowed?(media_id, owner, viewer) do
    {:ok, %{allowed: allowed}} =
      ScyllaAdapter.media_download_allowed(%{
        "media_id" => media_id,
        "owner_user_id" => owner,
        "viewer_user_id" => viewer
      })

    allowed
  end

  # --- THE BATTERY ----------------------------------------------------------------------------------

  test "BROADCAST: one asset fanned to three DMs — all three recipients allowed, a fourth denied" do
    owner = user!()
    [b, c, d, uninvolved] = for _ <- 1..4, do: user!()
    media = Ecto.UUID.generate()

    for recipient <- [b, c, d] do
      conv = conversation!([owner, recipient])
      media!(conv, owner, media)
    end

    # An unrelated conversation the uninvolved user IS in — membership alone must not grant.
    _other = conversation!([uninvolved, user!()])

    assert allowed?(media, owner, b)
    assert allowed?(media, owner, c)
    assert allowed?(media, owner, d)
    refute allowed?(media, owner, uninvolved)
  end

  test "PLANTED REFERENCE: B re-sends A's media_id into B<->C — C gains NOTHING (sender==owner is the leak defense)" do
    owner = user!()
    [b, c] = for _ <- 1..2, do: user!()
    media = Ecto.UUID.generate()

    # The legitimate send: owner -> B.
    conv_ab = conversation!([owner, b])
    media!(conv_ab, owner, media)

    # The plant: B references the same media_id in B<->C. The projection now names conv_bc — but the
    # sender of that reference is B, not the owner, so it must grant C nothing.
    conv_bc = conversation!([b, c])
    media!(conv_bc, b, media)

    # B is allowed (via the OWNER-sent reference in conv_ab) — the plant changes nothing for B.
    assert allowed?(media, owner, b)
    # C is DENIED: the only conversation C shares carries a NON-owner reference.
    # (Mutation-checked during development: with the sender==owner filter removed, this line goes
    # red — the plant would grant C access through conv_bc.)
    refute allowed?(media, owner, c)
  end

  test "left_at LIVE-DENY: departure bites immediately even though the projection still names the conversation" do
    owner = user!()
    b = user!()
    media = Ecto.UUID.generate()
    conv = conversation!([owner, b])
    media!(conv, owner, media)

    assert allowed?(media, owner, b)

    # B leaves — a POSTGRES fact. The Scylla projection is untouched and still lists conv.
    pg!(
      "UPDATE conversation_participants SET left_at = now() " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conv, b]
    )

    refute allowed?(media, owner, b)
  end

  test "PROJECTION ABSENT: authoritative row present, reference row missing — DENY and LOG LOUDLY" do
    owner = user!()
    b = user!()
    media = Ecto.UUID.generate()
    conv = conversation!([owner, b])
    message_id = media!(conv, owner, media)

    # Simulate the lost fan-out write: the authoritative row stays, the reference row vanishes.
    {:ok, _} =
      XandraAdapter.execute("DELETE FROM messages_by_media WHERE media_id = ?", [media], [])

    log =
      capture_log(fn ->
        refute allowed?(media, owner, b)
      end)

    # Fail-closed AND loud — a silent version of this denial is indistinguishable from a working
    # system, which is exactly how it hid for days last time.
    assert log =~ "NO REFERENCES"
    assert log =~ media
    assert log =~ "repair_media_projections"

    # And the stated recovery path actually recovers: repair from the authority, access returns.
    :ok = ScyllaAdapter.repair_media_projections(conv, message_id)
    assert allowed?(media, owner, b)
  end

  test "a CLEAN deny is quiet: references exist, the viewer simply is not in an owner-sent conversation" do
    owner = user!()
    b = user!()
    outsider = user!()
    media = Ecto.UUID.generate()
    media!(conversation!([owner, b]), owner, media)

    log =
      capture_log(fn ->
        refute allowed?(media, owner, outsider)
      end)

    refute log =~ "NO REFERENCES"
  end

  # --- the other five -------------------------------------------------------------------------------

  test "get_by_media_id returns the EARLIEST reference's conversation" do
    owner = user!()
    media = Ecto.UUID.generate()
    now = DateTime.utc_now()

    conv_late = conversation!([owner, user!()])
    conv_first = conversation!([owner, user!()])
    media!(conv_late, owner, media, DateTime.add(now, -60, :second))
    media!(conv_first, owner, media, DateTime.add(now, -300, :second))

    assert {:ok, %{conversation_id: ^conv_first}} =
             ScyllaAdapter.get_by_media_id(%{"media_id" => media})

    assert {:error, :not_found} =
             ScyllaAdapter.get_by_media_id(%{"media_id" => Ecto.UUID.generate()})
  end

  test "list_media: gallery newest-first; a DELETED item leaves the gallery via the tombstone rewrite" do
    owner = user!()
    viewer = user!()
    conv = conversation!([owner, viewer])
    now = DateTime.utc_now()

    [m1, m2] =
      for i <- [2, 1] do
        media!(conv, owner, Ecto.UUID.generate(), DateTime.add(now, -i * 60, :second))
      end

    {:ok, %{items: items}} =
      ScyllaAdapter.list_media(%{"conversation_id" => conv, "viewer_user_id" => viewer})

    assert Enum.map(items, & &1.message_id) == [m2, m1]

    # Delete the newest — the gallery tombstone rewrite must remove it from the page.
    {:ok, _} =
      ScyllaAdapter.delete_message(%{"conversation_id" => conv, "message_id" => m2})

    {:ok, %{items: items}} =
      ScyllaAdapter.list_media(%{"conversation_id" => conv, "viewer_user_id" => viewer})

    assert Enum.map(items, & &1.message_id) == [m1]

    # And the viewer's cleared_before window masks the rest.
    pg!(
      "UPDATE conversation_participants SET cleared_before = now() " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conv, viewer]
    )

    {:ok, %{items: items}} =
      ScyllaAdapter.list_media(%{"conversation_id" => conv, "viewer_user_id" => viewer})

    assert items == []
  end

  test "POLLS (iii): validation via the Scylla point-read + metadata-JSON definition; votes stay Postgres" do
    owner = user!()
    voter = user!()
    conv = conversation!([owner, voter])

    poll = %{
      "question" => "lunch?",
      "allows_multiple" => false,
      "options" => [%{"id" => "o1", "text" => "pizza"}, %{"id" => "o2", "text" => "sushi"}]
    }

    message_id =
      put!(conv, owner, %{
        "message_type" => "poll",
        "body" => "lunch?",
        "metadata" => %{"poll" => poll}
      })

    vote = fn user, options ->
      ScyllaAdapter.poll_vote(%{
        "conversation_id" => conv,
        "message_id" => message_id,
        "user_id" => user,
        "option_ids" => options
      })
    end

    # First vote, then CHANGE (replace-the-set semantics).
    assert {:ok, %{poll: aggregate}} = vote.(voter, ["o1"])
    assert Enum.find(aggregate.options, &(&1.id == "o1")).count == 1

    assert {:ok, %{poll: aggregate}} = vote.(voter, ["o2"])
    assert Enum.find(aggregate.options, &(&1.id == "o1")).count == 0
    assert Enum.find(aggregate.options, &(&1.id == "o2")).count == 1

    # The gates, exactly as Postgres: unknown option, single-choice violation, wrong conversation.
    assert {:error, :poll_invalid_option} = vote.(voter, ["nope"])
    assert {:error, :poll_single_choice} = vote.(voter, ["o1", "o2"])

    other_conv = conversation!([owner, voter])

    assert {:error, :message_not_found} =
             ScyllaAdapter.poll_vote(%{
               "conversation_id" => other_conv,
               "message_id" => message_id,
               "user_id" => voter,
               "option_ids" => ["o1"]
             })

    # The uncapped voter list endpoint reads the same truth.
    assert {:ok, %{poll: listed}} =
             ScyllaAdapter.list_poll_votes(%{"conversation_id" => conv, "message_id" => message_id})

    assert Enum.find(listed.options, &(&1.id == "o2")).count == 1
  end

  test "MESSAGE_INFO (ii): reciprocity to the Postgres suite's own expectations" do
    sender = user!()
    reader_on = user!()
    reader_off = user!()
    delivered_only = user!()
    conv = conversation!([sender, reader_on, reader_off, delivered_only])

    # reader_off disabled receipts (the reader half of reciprocity).
    pg!(
      "INSERT INTO user_privacy_settings (user_id, read_receipts_enabled) VALUES ($1::text::uuid, false) " <>
        "ON CONFLICT (user_id) DO UPDATE SET read_receipts_enabled = false",
      [reader_off]
    )

    message_id = put!(conv, sender)

    mark = fn user, fun ->
      {:ok, _} =
        apply(ScyllaAdapter, fun, [
          %{"conversation_id" => conv, "message_id" => message_id, "user_id" => user}
        ])
    end

    # delivered -> read upgrades for both readers; delivered_only stays delivered.
    mark.(reader_on, :mark_delivered)
    mark.(reader_on, :mark_read)
    mark.(reader_off, :mark_delivered)
    mark.(reader_off, :mark_read)
    mark.(delivered_only, :mark_delivered)

    {:ok, info} =
      ScyllaAdapter.message_info(%{
        "conversation_id" => conv,
        "message_id" => message_id,
        "viewer_user_id" => sender
      })

    # THE RULE, exactly as MessageService.MessageInfoTest pins it for Postgres: the receipts-off
    # reader is ABSENT from read and PRESENT in delivered (their read is undisclosed, their receipt
    # of the bytes is not); the receipts-on reader is in read only; delivered_only in delivered.
    assert Enum.map(info.read, & &1.user_id) == [reader_on]
    assert info.read_hidden == false

    delivered_ids = info.delivered |> Enum.map(& &1.user_id) |> Enum.sort()
    assert delivered_ids == Enum.sort([reader_off, delivered_only])

    # AND both timestamps survived the delivered->read upgrade (the 003 contact fix): reader_off's
    # delivered_at is the true DELIVERED time, not their read time... at minimum it is present.
    off_row = Enum.find(info.delivered, &(&1.user_id == reader_off))
    assert %DateTime{} = off_row.delivered_at

    # A receipts-off VIEWER: read [] + read_hidden true, delivered intact (the owner half).
    pg!(
      "INSERT INTO user_privacy_settings (user_id, read_receipts_enabled) VALUES ($1::text::uuid, false) " <>
        "ON CONFLICT (user_id) DO UPDATE SET read_receipts_enabled = false",
      [sender]
    )

    {:ok, hidden_info} =
      ScyllaAdapter.message_info(%{
        "conversation_id" => conv,
        "message_id" => message_id,
        "viewer_user_id" => sender
      })

    assert hidden_info.read == []
    assert hidden_info.read_hidden == true
    assert length(hidden_info.delivered) >= 2

    # Sender-only + tombstone gates.
    assert {:error, :not_sender} =
             ScyllaAdapter.message_info(%{
               "conversation_id" => conv,
               "message_id" => message_id,
               "viewer_user_id" => reader_on
             })
  end
end
