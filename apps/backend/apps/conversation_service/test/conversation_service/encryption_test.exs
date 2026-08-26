defmodule ConversationService.EncryptionTest do
  @moduledoc """
  Secret-chat control plane (108) on real SQL: enable preconditions (direct only, member only —
  unknown and non-member are the SAME :conversation_not_found, no reveal; both members need a live
  device key from 107, and the error NAMES the missing side), ONE-WAY enable (disable refused —
  recorded decision), idempotent re-enable, create-with-secret running the same preconditions
  BEFORE the insert, and the keys_changed fan-out lookup.
  """
  use ConversationService.DataCase, async: false

  alias ConversationService.Conversations
  alias ConversationService.Encryption

  @tenant_zero "00000000-0000-0000-0000-000000000001"

  setup do
    prev = Application.get_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:conversation_service, :conversation_persistence, true)
    on_exit(fn -> Application.put_env(:conversation_service, :conversation_persistence, prev) end)
    :ok
  end

  defp user!(with_keys? \\ true) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, password_hash, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', 'active', now(), now())",
      [id, @tenant_zero, "+1#{System.unique_integer([:positive])}"]
    )

    if with_keys? do
      device = "dev-#{System.unique_integer([:positive])}"

      Repo.query!(
        "INSERT INTO device_sessions (id, user_id, device_id, platform, refresh_token_hash, created_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, $3, 'android', 'h', now())",
        [Ecto.UUID.generate(), id, device]
      )

      Repo.query!(
        "INSERT INTO device_keys (user_id, device_id, app_id, ed25519_public, x25519_public) " <>
          "VALUES ($1::text::uuid, $2, $3::text::uuid, $4, $5)",
        [id, device, @tenant_zero, :binary.copy(<<1>>, 32), :binary.copy(<<2>>, 32)]
      )
    end

    id
  end

  defp conversation!(members, type \\ "direct") do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, $4::text::uuid, 'active', now(), now())",
      [id, @tenant_zero, type, hd(members)]
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

  defp enable(conversation, user, enabled \\ true) do
    Encryption.set_encryption(%{
      "conversation_id" => conversation,
      "user_id" => user,
      "enabled" => enabled
    })
  end

  defp secret?(conversation) do
    %{rows: [[value]]} =
      Repo.query!("SELECT secret FROM conversations WHERE id = $1::text::uuid", [conversation])

    value
  end

  @tag :postgres_integration
  test "preconditions: group refused, non-member/unknown are the same 404, missing keys NAMED" do
    a = user!()
    b = user!()
    no_keys = user!(false)
    outsider = user!()

    group = conversation!([a, b], "group")
    assert {:error, :secret_not_supported} = enable(group, a)

    direct = conversation!([a, b])
    assert {:error, :conversation_not_found} = enable(direct, outsider)
    assert {:error, :conversation_not_found} = enable(Ecto.UUID.generate(), a)

    # The keyless SIDE is named — the client can prompt the right person.
    keyless_chat = conversation!([a, no_keys])
    assert {:error, {:secret_peer_keys_missing, [^no_keys]}} = enable(keyless_chat, a)
    refute secret?(keyless_chat)

    # A key on a REVOKED device does not count.
    revoked_only = user!(false)

    Repo.query!(
      "INSERT INTO device_sessions (id, user_id, device_id, platform, refresh_token_hash, revoked_at, created_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'dead', 'android', 'h', now(), now())",
      [Ecto.UUID.generate(), revoked_only]
    )

    Repo.query!(
      "INSERT INTO device_keys (user_id, device_id, app_id, ed25519_public, x25519_public) " <>
        "VALUES ($1::text::uuid, 'dead', $2::text::uuid, $3, $4)",
      [revoked_only, @tenant_zero, :binary.copy(<<9>>, 32), :binary.copy(<<8>>, 32)]
    )

    dead_chat = conversation!([a, revoked_only])
    assert {:error, {:secret_peer_keys_missing, [^revoked_only]}} = enable(dead_chat, a)
  end

  @tag :postgres_integration
  test "enable is ONE-WAY and idempotent; secret_conversations_of lists it" do
    a = user!()
    b = user!()
    direct = conversation!([a, b])

    assert {:ok, %{enabled: true, already: false, member_ids: members}} = enable(direct, a)
    assert Enum.sort(members) == Enum.sort([a, b])
    assert secret?(direct)

    # Idempotent re-enable; DISABLE is refused (recorded decision — one-way in v1).
    assert {:ok, %{already: true}} = enable(direct, b)
    assert {:error, :secret_cannot_disable} = enable(direct, a, false)
    assert secret?(direct)

    assert {:ok, %{conversation_ids: [^direct]}} =
             Encryption.secret_conversations_of(%{"user_id" => a})
  end

  @tag :postgres_integration
  test "CREATE with secret: true runs the SAME preconditions BEFORE the insert" do
    a = user!()
    b = user!()
    no_keys = user!(false)

    # Refused secret creates leave NOTHING behind.
    assert {:error, {:secret_peer_keys_missing, [^no_keys]}} =
             Conversations.create_conversation(%{
               "type" => "direct",
               "created_by" => a,
               "participant_user_ids" => [no_keys],
               "secret" => true
             })

    assert {:error, :secret_not_supported} =
             Conversations.create_conversation(%{
               "type" => "group",
               "title" => "G",
               "created_by" => a,
               "participant_user_ids" => [b],
               "secret" => true
             })

    %{rows: [[count]]} =
      Repo.query!("SELECT count(*)::int FROM conversations WHERE created_by = $1::text::uuid", [a])

    assert count == 0

    # A qualifying pair creates secret from birth.
    assert {:ok, created} =
             Conversations.create_conversation(%{
               "type" => "direct",
               "created_by" => a,
               "participant_user_ids" => [b],
               "secret" => true
             })

    assert secret?(created.conversation_id)
  end

  # ---- v2 (109): opportunistic auto-secret at create -----------------------------------------------

  # A fresh live app; `e2ee_default` toggled per case.
  defp app!(e2ee_default) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO apps (id, name, slug, mode, e2ee_default) " <>
        "VALUES ($1::text::uuid, 'T', $2, 'live', $3)",
      [id, "t-#{id}", e2ee_default]
    )

    id
  end

  defp create_direct(app_id, creator, peer) do
    Conversations.create_conversation(%{
      "type" => "direct",
      "app_id" => app_id,
      "created_by" => creator,
      "participant_user_ids" => [peer]
    })
  end

  defp appuser!(app_id, with_keys?) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, password_hash, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', 'active', now(), now())",
      [id, app_id, "+1#{System.unique_integer([:positive])}"]
    )

    if with_keys? do
      device = "dev-#{System.unique_integer([:positive])}"

      Repo.query!(
        "INSERT INTO device_sessions (id, user_id, device_id, platform, refresh_token_hash, created_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, $3, 'android', 'h', now())",
        [Ecto.UUID.generate(), id, device]
      )

      Repo.query!(
        "INSERT INTO device_keys (user_id, device_id, app_id, ed25519_public, x25519_public) " <>
          "VALUES ($1::text::uuid, $2, $3::text::uuid, $4, $5)",
        [id, device, app_id, :binary.copy(<<1>>, 32), :binary.copy(<<2>>, 32)]
      )
    end

    id
  end

  @tag :postgres_integration
  test "AUTO-SECRET matrix (109): born secret ONLY when app flag on AND both members have keys" do
    on_app = app!(true)
    off_app = app!(false)

    # flag ON, both keyed → BORN SECRET (no explicit "secret" flag).
    a1 = appuser!(on_app, true)
    b1 = appuser!(on_app, true)
    assert {:ok, c1} = create_direct(on_app, a1, b1)
    assert c1.created == true
    assert secret?(c1.conversation_id)

    # flag ON, one keyless → stays NORMAL (NOT an error — old clients keep working).
    a2 = appuser!(on_app, true)
    b2 = appuser!(on_app, false)
    assert {:ok, c2} = create_direct(on_app, a2, b2)
    refute secret?(c2.conversation_id)

    # flag OFF, both keyed → stays NORMAL.
    a3 = appuser!(off_app, true)
    b3 = appuser!(off_app, true)
    assert {:ok, c3} = create_direct(off_app, a3, b3)
    refute secret?(c3.conversation_id)
  end

  @tag :postgres_integration
  test "KEYLESS pair in a default-on app never upgrades; plaintext send is accepted there" do
    on_app = app!(true)
    a = appuser!(on_app, false)
    b = appuser!(on_app, false)

    assert {:ok, conversation} = create_direct(on_app, a, b)
    refute secret?(conversation.conversation_id)

    # The keyless-pair conversation is a NORMAL chat: the send-gate policy accepts plaintext (proven
    # by the message-service secret suite; here we assert the conversation itself never flipped, even
    # on a second open — no create-time upgrade, and the client-driven trigger has no keys to act on).
    assert {:ok, again} = create_direct(on_app, a, b)
    assert again.conversation_id == conversation.conversation_id
    refute secret?(conversation.conversation_id)
  end
end
