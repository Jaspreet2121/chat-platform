defmodule ConversationService.EncryptionTest do
  @moduledoc """
  Secret-chat control plane (108; two-party OFF in 118) on real SQL: enable preconditions (direct
  only, member only — unknown and non-member are the SAME :conversation_not_found, no reveal; both
  members need a live device key from 107, and the error NAMES the missing side), idempotent
  re-enable, create-with-secret running the same preconditions BEFORE the insert, the keys_changed
  fan-out lookup — and the 118 contract: a single-sided OFF NEVER flips the flag (it records a
  request), the OTHER member's own OFF is the acceptance, the requester cannot self-accept, ON
  clears both the pending request and the explicit-off marker, a request expires after 7 days, and
  only the requester can cancel.
  """
  use ConversationService.DataCase, async: false

  alias ConversationService.Conversations
  alias ConversationService.Encryption

  @tenant_zero "00000000-0000-0000-0000-000000000001"

  @result_keys [:already, :change, :e2ee_disabled, :enabled, :member_ids, :off_pending]

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

  defp off(conversation, user), do: enable(conversation, user, false)

  defp cancel(conversation, user) do
    Encryption.set_encryption(%{
      "conversation_id" => conversation,
      "user_id" => user,
      "enabled" => false,
      "cancel" => true
    })
  end

  defp secret?(conversation) do
    %{rows: [[value]]} =
      Repo.query!("SELECT secret FROM conversations WHERE id = $1::text::uuid", [conversation])

    value
  end

  # The three 118 columns, straight from the row — the store's result is never trusted to prove
  # its own writes.
  defp columns(conversation) do
    %{rows: [[secret, disabled_at, requested_by, requested_at]]} =
      Repo.query!(
        "SELECT secret, e2ee_disabled_at, e2ee_off_requested_by::text, e2ee_off_requested_at " <>
          "FROM conversations WHERE id = $1::text::uuid",
        [conversation]
      )

    %{
      secret: secret,
      disabled_at: disabled_at,
      requested_by: requested_by,
      requested_at: requested_at
    }
  end

  defp backdate!(conversation, days) do
    Repo.query!(
      "UPDATE conversations SET e2ee_off_requested_at = now() - ($2 || ' days')::interval " <>
        "WHERE id = $1::text::uuid",
      [conversation, Integer.to_string(days)]
    )
  end

  defp detail(conversation, user) do
    {:ok, detail} =
      Conversations.get_conversation(%{"conversation_id" => conversation, "user_id" => user})

    detail
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
  test "ON is either-party, immediate, idempotent; a bare single-sided OFF NEVER changes secret; secret_conversations_of lists it" do
    a = user!()
    b = user!()
    direct = conversation!([a, b])

    assert {:ok,
            %{enabled: true, already: false, change: "enabled", member_ids: members} = result} =
             enable(direct, a)

    assert Map.keys(result) |> Enum.sort() == @result_keys
    assert Enum.sort(members) == Enum.sort([a, b])
    assert secret?(direct)

    # Idempotent re-enable from the other side: nothing moved, nothing to announce.
    assert {:ok, %{enabled: true, already: true, change: nil}} = enable(direct, b)

    # A bare single-sided OFF is recorded as a REQUEST and the flag is untouched — the v1 rule
    # (no one-sided downgrade) survives 118 unchanged.
    assert {:ok, %{enabled: true, change: "off_requested"}} = off(direct, a)
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

  # ---- 118: two-party OFF ---------------------------------------------------------------------------

  @tag :postgres_integration
  test "OFF is TWO-PARTY: A's request records without flipping; B's own OFF accepts, flips, stamps the marker; ON clears both" do
    a = user!()
    b = user!()
    direct = conversation!([a, b])
    {:ok, _} = enable(direct, a)

    # A requests. The flag does NOT move (MUT-1); the request is on the row and in the detail.
    assert {:ok, request} = off(direct, a)
    assert Map.keys(request) |> Enum.sort() == @result_keys

    assert %{
             enabled: true,
             already: false,
             change: "off_requested",
             e2ee_disabled: false,
             off_pending: %{requested_by: ^a, requested_at: requested_at}
           } = request

    assert {:ok, _, _} = DateTime.from_iso8601(requested_at)
    assert secret?(direct)
    assert %{requested_by: ^a, requested_at: %DateTime{}, disabled_at: nil} = columns(direct)

    # The other member's detail fetch carries the pending request, nested, and the marker false.
    seen_by_b = detail(direct, b)
    assert seen_by_b.secret == true
    assert seen_by_b.e2ee_disabled == false
    assert seen_by_b.e2ee_off_pending == %{requested_by: a, requested_at: requested_at}

    # B's own OFF is the acceptance: the ONLY call that ever flips to plain; the marker is stamped.
    assert {:ok, accepted} = off(direct, b)

    assert %{
             enabled: false,
             already: false,
             change: "disabled",
             e2ee_disabled: true,
             off_pending: nil
           } = accepted

    refute secret?(direct)

    assert %{secret: false, disabled_at: %DateTime{}, requested_by: nil, requested_at: nil} =
             columns(direct)

    seen_by_a = detail(direct, a)
    assert seen_by_a.secret == false
    assert seen_by_a.e2ee_disabled == true
    assert seen_by_a.e2ee_off_pending == nil

    # A further OFF on a plain chat is idempotent — nothing to request.
    assert {:ok, %{enabled: false, already: true, change: nil, e2ee_disabled: true}} =
             off(direct, a)

    assert columns(direct).requested_by == nil

    # ON from either side clears the explicit-off marker (MUT-4) — otherwise the client-side
    # opportunistic upgrade would treat the chat as "turned off" forever.
    assert {:ok, %{enabled: true, already: false, change: "enabled", e2ee_disabled: false}} =
             enable(direct, b)

    assert secret?(direct)
    assert %{disabled_at: nil, requested_by: nil} = columns(direct)
    assert detail(direct, a).e2ee_disabled == false
  end

  @tag :postgres_integration
  test "SELF-ACCEPT is impossible: the requester's repeat OFF is the SAME request — no flip, no second request" do
    a = user!()
    b = user!()
    direct = conversation!([a, b])
    {:ok, _} = enable(direct, a)

    {:ok, %{off_pending: %{requested_at: first}}} = off(direct, a)

    # MUT-2: the requester asking again must never be read as the other party accepting.
    assert {:ok,
            %{
              enabled: true,
              already: true,
              change: nil,
              off_pending: %{requested_by: ^a, requested_at: ^first}
            }} = off(direct, a)

    assert secret?(direct)
    assert columns(direct).requested_by == a
  end

  @tag :postgres_integration
  test "ON from either side INVALIDATES a pending request; the next OFF starts fresh, it does not accept" do
    a = user!()
    b = user!()
    direct = conversation!([a, b])
    {:ok, _} = enable(direct, a)
    {:ok, _} = off(direct, a)

    # MUT-3: B turning ON again is an "off_cancelled" change with the request gone.
    assert {:ok, %{enabled: true, already: true, change: "off_cancelled", off_pending: nil}} =
             enable(direct, b)

    assert secret?(direct)
    assert %{requested_by: nil, requested_at: nil} = columns(direct)

    # ...so B's OFF now is a NEW request by B, never an acceptance of A's dead one.
    assert {:ok, %{enabled: true, change: "off_requested", off_pending: %{requested_by: ^b}}} =
             off(direct, b)

    assert secret?(direct)
  end

  @tag :postgres_integration
  test "EXPIRY: a request older than 7 days is ABSENT — the other side's OFF starts fresh; a 6-day-old one is honoured; the detail read cleans the stale row" do
    a = user!()
    b = user!()
    direct = conversation!([a, b])
    {:ok, _} = enable(direct, a)

    {:ok, _} = off(direct, a)
    backdate!(direct, 8)

    # MUT-5: B's OFF must NOT accept an 8-day-old request — it records B's own.
    assert {:ok, %{enabled: true, change: "off_requested", off_pending: %{requested_by: ^b}}} =
             off(direct, b)

    assert secret?(direct)

    # Inside the window the request still counts: A accepts B's 6-day-old request.
    backdate!(direct, 6)
    assert {:ok, %{enabled: false, change: "disabled"}} = off(direct, a)
    refute secret?(direct)

    # The READ path: a stale request is reported absent and cleared from the row.
    {:ok, _} = enable(direct, a)
    {:ok, _} = off(direct, a)
    backdate!(direct, 8)

    assert detail(direct, b).e2ee_off_pending == nil
    assert %{requested_by: nil, requested_at: nil} = columns(direct)
  end

  @tag :postgres_integration
  test "CANCEL: the requester withdraws; the other member cannot; nothing pending is idempotent" do
    a = user!()
    b = user!()
    direct = conversation!([a, b])
    {:ok, _} = enable(direct, a)
    {:ok, _} = off(direct, a)

    assert {:error, :secret_not_requester} = cancel(direct, b)
    assert columns(direct).requested_by == a

    assert {:ok, %{enabled: true, already: false, change: "off_cancelled", off_pending: nil}} =
             cancel(direct, a)

    assert %{requested_by: nil, requested_at: nil} = columns(direct)
    assert secret?(direct)

    assert {:ok, %{enabled: true, already: true, change: nil, off_pending: nil}} =
             cancel(direct, a)
  end

  @tag :postgres_integration
  test "GROUP refuses OFF and cancel like ON; non-member/unknown are ONE answer for all three and record NOTHING; malformed bodies refuse" do
    a = user!()
    b = user!()
    outsider = user!()

    # MUT-6: a group owner's OFF is :secret_not_supported, never a recorded request.
    group = conversation!([a, b], "group")
    assert {:error, :secret_not_supported} = off(group, a)
    assert {:error, :secret_not_supported} = cancel(group, a)
    assert columns(group).requested_by == nil

    direct = conversation!([a, b])
    {:ok, _} = enable(direct, a)

    # MUT-7 (store half): unknown id and non-member are byte-identical refusals for every shape,
    # and the outsider's OFF leaves no request behind.
    for call <- [&enable/2, &off/2, &cancel/2] do
      assert {:error, :conversation_not_found} = call.(direct, outsider)
      assert {:error, :conversation_not_found} = call.(Ecto.UUID.generate(), a)
    end

    assert %{secret: true, requested_by: nil} = columns(direct)

    assert {:error, :secret_invalid} =
             Encryption.set_encryption(%{"conversation_id" => direct, "user_id" => a})

    assert {:error, :secret_invalid} =
             Encryption.set_encryption(%{
               "conversation_id" => direct,
               "user_id" => a,
               "enabled" => false,
               "cancel" => "yes"
             })

    assert {:error, :conversation_invalid} =
             Encryption.set_encryption(%{
               "conversation_id" => "nope",
               "user_id" => a,
               "enabled" => true
             })
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
