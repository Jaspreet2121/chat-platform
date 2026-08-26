defmodule MessageService.SecretMessagesTest do
  @moduledoc """
  Sealed messages + the server content gates (108), live against both engines through the FULL
  Messages.create_message path:

    * type policy BOTH directions (plaintext into secret → 422 atom; sealed into normal → 422);
    * sealed shape/size/recipients validation (client_msg_id required, foreign device refused);
    * the 107 dedup applies to sealed sends;
    * SYSTEM messages stay accepted in a secret chat (plaintext protocol state, no user content);
    * CONTENT GATES, each mutation-proven by its own assertion: search index skips (no
      message_search row), webhook payload body is nil for sealed (read from the staged
      webhook_outbox row), inbox preview is the fixed 🔒 marker, stored body is nil (nothing for a
      gallery/link extractor to read — none exists server-side, and media_id is inside the
      ciphertext by design).
  """
  use ExUnit.Case, async: false

  alias MessageService.Messages
  alias MessageService.Repo
  alias SharedInfra.Scylla.XandraAdapter

  @moduletag :scylla_integration

  @cluster SharedInfra.Scylla.XandraAdapter.Cluster
  @tenant_zero "00000000-0000-0000-0000-000000000001"

  setup_all do
    nodes =
      System.get_env("SCYLLA_TEST_NODES", "localhost:9042") |> String.split(",", trim: true)

    ensure_no_cluster()
    {:ok, _pid} = XandraAdapter.start_link(nodes: nodes, keyspace: "chat_messages")
    Process.sleep(2_000)

    previous = %{
      scylla: Application.get_env(:message_service, :scylla_client_adapter),
      store: Application.get_env(:message_service, :message_store_adapter),
      persistence: Application.get_env(:message_service, :message_persistence)
    }

    Application.put_env(:message_service, :scylla_client_adapter, XandraAdapter)

    Application.put_env(
      :message_service,
      :message_store_adapter,
      MessageService.MessageStore.ScyllaAdapter
    )

    Application.put_env(:message_service, :message_persistence, true)

    on_exit(fn ->
      restore = fn key, value ->
        if value,
          do: Application.put_env(:message_service, key, value),
          else: Application.delete_env(:message_service, key)
      end

      restore.(:scylla_client_adapter, previous.scylla)
      restore.(:message_store_adapter, previous.store)
      restore.(:message_persistence, previous.persistence)
      ensure_no_cluster()
    end)

    :ok
  end

  setup do
    case Repo.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    # A webhook endpoint so sealed creates STAGE a payload we can inspect.
    Repo.query!(
      "INSERT INTO webhook_endpoints (app_id, url, signing_secret, enabled, event_types) " <>
        "VALUES ($1::text::uuid, 'https://integrator.test/hook', 'secret', true, ARRAY['message.created'])",
      [@tenant_zero]
    )

    [a, b] =
      for _ <- 1..2 do
        id = Ecto.UUID.generate()

        Repo.query!(
          "INSERT INTO users_auth (id, app_id, external_id, email, password_hash, created_at, updated_at) " <>
            "VALUES ($1::text::uuid, $2::text::uuid, $3, $4, 'x', now(), now())",
          [id, @tenant_zero, "ext-#{id}", "#{id}@test.local"]
        )

        id
      end

    devices =
      for {user, device} <- [{a, "dev-a"}, {b, "dev-b"}] do
        Repo.query!(
          "INSERT INTO device_sessions (id, user_id, device_id, platform, refresh_token_hash, created_at) " <>
            "VALUES ($1::text::uuid, $2::text::uuid, $3, 'android', 'h', now())",
          [Ecto.UUID.generate(), user, device]
        )

        device
      end

    conversation = conversation!([a, b], secret: true)
    normal = conversation!([a, b], secret: false)

    {:ok, a: a, b: b, devices: devices, secret_conv: conversation, normal_conv: normal}
  end

  defp conversation!(members, opts) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, status, secret, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'direct', $3::text::uuid, 'active', $4, now(), now())",
      [id, @tenant_zero, hd(members), Keyword.get(opts, :secret, false)]
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

  defp sealed_payload(devices, over \\ %{}) do
    Map.merge(
      %{
        "v" => 1,
        "alg" => "xchacha20poly1305+x25519",
        "sender_device_id" => Enum.at(devices, 0),
        "sig_b64" => Base.encode64("sig"),
        "recipients" =>
          Enum.map(devices, fn device ->
            %{"device_id" => device, "envelope_b64" => Base.encode64("ciphertext")}
          end)
      },
      over
    )
  end

  defp send_sealed(conversation, sender, devices, over \\ %{}) do
    Messages.create_message(
      Map.merge(
        %{
          "conversation_id" => conversation,
          "sender_user_id" => sender,
          "message_type" => "sealed",
          "client_msg_id" => Ecto.UUID.generate(),
          "sealed" => sealed_payload(devices)
        },
        over
      )
    )
  end

  @tag :scylla_integration
  test "TYPE POLICY, both directions; system stays welcome in a secret chat",
       %{a: a, secret_conv: secret, normal_conv: normal, devices: devices} do
    assert {:error, :secret_plaintext_rejected} =
             Messages.create_message(%{
               "conversation_id" => secret,
               "sender_user_id" => a,
               "message_type" => "text",
               "body" => "leak"
             })

    assert {:error, :secret_sealed_rejected} = send_sealed(normal, a, devices)

    # System messages carry protocol state only — plaintext BY DESIGN, accepted in a secret chat.
    assert {:ok, system} =
             Messages.create_message(%{
               "conversation_id" => secret,
               "sender_user_id" => a,
               "message_type" => "system",
               "metadata" => %{"kind" => "encryption", "state" => "enabled", "by" => a}
             })

    assert system.metadata["kind"] == "encryption"
  end

  @tag :scylla_integration
  test "SEALED validation: shape, client_msg_id required, foreign device refused, 64KB cap",
       %{a: a, secret_conv: secret, devices: devices} do
    # No client_msg_id → refused (the 107 dedup is mandatory for sealed sends).
    assert {:error, :secret_sealed_invalid} =
             send_sealed(secret, a, devices, %{"client_msg_id" => nil})

    # A recipient device that belongs to NEITHER member.
    assert {:error, :secret_sealed_invalid} =
             send_sealed(secret, a, devices ++ ["foreign-device"])

    # Malformed shapes.
    assert {:error, :secret_sealed_invalid} =
             send_sealed(secret, a, devices, %{"sealed" => %{"v" => 2}})

    assert {:error, :secret_sealed_invalid} =
             send_sealed(secret, a, devices, %{
               "sealed" => sealed_payload(devices, %{"recipients" => []})
             })

    # The 64KB cap.
    huge = sealed_payload(devices, %{"pad" => String.duplicate("x", 70_000)})
    assert {:error, :secret_sealed_invalid} = send_sealed(secret, a, devices, %{"sealed" => huge})
  end

  @tag :scylla_integration
  test "SEALED accepted: opaque storage, nil body, dedup applies, EVERY content gate holds",
       %{a: a, secret_conv: secret, devices: devices} do
    client_id = Ecto.UUID.generate()

    assert {:ok, message} = send_sealed(secret, a, devices, %{"client_msg_id" => client_id})

    # Opaque storage: the envelope round-trips untouched; the body is nil (nothing for any
    # gallery/link extractor — none exists server-side, and media rides inside the ciphertext).
    assert message.body == nil
    assert message.metadata["sealed"]["recipients"] |> length() == 2
    assert message.metadata["sealed"]["alg"] == "xchacha20poly1305+x25519"

    # 107 dedup applies to sealed sends.
    assert {:ok, resent} = send_sealed(secret, a, devices, %{"client_msg_id" => client_id})
    assert resent.message_id == message.message_id

    # GATE: search index — the consumer-side upsert refuses sealed/secret rows.
    MessageService.Projections.SearchIndex.upsert(%{
      message_id: message.message_id,
      conversation_id: secret,
      sender_user_id: a,
      created_at: DateTime.utc_now(),
      body: "should never land",
      message_type: "sealed"
    })

    %{rows: [[indexed]]} =
      Repo.query!(
        "SELECT count(*)::int FROM message_search WHERE conversation_id = $1::text::uuid",
        [secret]
      )

    assert indexed == 0

    # GATE: even a SYSTEM row in a secret conversation stays out of the index.
    MessageService.Projections.SearchIndex.upsert(%{
      message_id: Ecto.UUID.generate(),
      conversation_id: secret,
      sender_user_id: a,
      created_at: DateTime.utc_now(),
      body: "encryption enabled",
      message_type: "system"
    })

    %{rows: [[indexed2]]} =
      Repo.query!(
        "SELECT count(*)::int FROM message_search WHERE conversation_id = $1::text::uuid",
        [secret]
      )

    assert indexed2 == 0

    # GATE: webhook — the staged payload says a sealed message HAPPENED, never what. (The payload
    # column holds a jsonb STRING scalar — the outbox stores the pre-encoded JSON — so decode it.)
    %{rows: outbox_rows} =
      Repo.query!("SELECT payload FROM webhook_outbox ORDER BY created_at DESC", [])

    # Exactly ONE webhook row despite the resend (107 dedup covers webhooks too).
    assert length(outbox_rows) == 1
    [[payload_raw]] = outbox_rows
    payload = if is_binary(payload_raw), do: Jason.decode!(payload_raw), else: payload_raw

    assert payload["conversation_id"] == secret
    assert payload["message_type"] == "sealed"
    assert payload["body"] == nil
    refute Map.has_key?(payload, "sealed")
    refute Map.has_key?(payload, "metadata")

    # GATE: inbox preview — the fixed marker, never a body.
    MessageService.InboxProjection.record_message(%{
      conversation_id: secret,
      message_id: message.message_id,
      created_at: DateTime.utc_now(),
      body: nil,
      message_type: "sealed",
      metadata: %{},
      sender_user_id: a
    })

    %{rows: [[preview]]} =
      Repo.query!(
        "SELECT last_message_body FROM conversations WHERE id = $1::text::uuid",
        [secret]
      )

    assert preview == "🔒 Message"
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
end
