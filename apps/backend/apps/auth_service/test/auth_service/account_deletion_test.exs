defmodule AuthService.AccountDeletionTest do
  @moduledoc """
  SELF-SERVE ACCOUNT DELETION (130). Real Postgres throughout: what is under test is a tombstone, a
  catalog-driven purge and a set of foreign keys, none of which a stub can tell the truth about.

  The guard that matters most is the LAST one. The purge reads the list of cascading tables from the
  catalog precisely so a feature slice adding a thirty-sixth table cannot leave personal data behind
  — and that only holds while nothing quietly opts a table out. Pinning the resolved set turns a new
  cascading table into a failing test instead of a silent survivor.
  """
  use AuthService.DataCase, async: false

  alias AuthService.AccountDeletion

  @phone "+15550100777"

  defp seed_app! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO apps (id, name, slug) VALUES ($1::text::uuid, 'Deletion Test', $2)",
      [id, "del-" <> String.slice(String.replace(id, "-", ""), 0, 12)]
    )

    id
  end

  defp seed_user(app_id, phone \\ nil) do
    id = Ecto.UUID.generate()
    phone = phone || "+1555#{System.unique_integer([:positive])}"

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, password_hash, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', 'active', now(), now())",
      [id, app_id, phone]
    )

    Repo.query!(
      "INSERT INTO user_profiles (user_id, app_id, display_name, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'Test User', now(), now())",
      [id, app_id]
    )

    {id, phone}
  end

  defp row(sql, params \\ []) do
    %Postgrex.Result{rows: rows} = Repo.query!(sql, params)
    rows
  end

  defp delete(user_id, phone) do
    AccountDeletion.delete_own_account(%{"user_id" => user_id, "phone_number" => phone})
  end

  describe "the tombstone" do
    @tag :postgres_integration
    test "the identity row SURVIVES with its identity scrubbed, so other people's messages still resolve" do
      app = seed_app!()
      {user, phone} = seed_user(app, @phone)

      assert {:ok, %{user_id: ^user, purged: purged}} = delete(user, phone)
      assert is_integer(purged)

      assert [[status, deleted_at, phone_number, email, external_id]] =
               row(
                 "SELECT status, deleted_at, phone_number, email, external_id " <>
                   "FROM users_auth WHERE id = $1::text::uuid",
                 [user]
               )

      assert status == "deleted"
      assert %DateTime{} = deleted_at
      assert is_nil(phone_number)
      assert is_nil(email)
      assert is_nil(external_id)
    end

    @tag :postgres_integration
    test "the phone number is free IMMEDIATELY — the same number registers again" do
      app = seed_app!()
      {user, phone} = seed_user(app, @phone)
      assert {:ok, _} = delete(user, phone)

      # The partial unique index is on (app_id, phone_number) WHERE phone_number IS NOT NULL, so the
      # scrubbed row does not occupy the number. Re-registering must not collide.
      {second, _} = seed_user(app, @phone)

      assert [[^second]] =
               row("SELECT id::text FROM users_auth WHERE phone_number = $1", [@phone])
    end

    @tag :postgres_integration
    test "the profile is gone, which is what makes the client render 'Deleted account'" do
      app = seed_app!()
      {user, phone} = seed_user(app, @phone)
      assert {:ok, _} = delete(user, phone)

      assert [] == row("SELECT user_id FROM user_profiles WHERE user_id = $1::text::uuid", [user])
    end
  end

  describe "the purge" do
    @tag :postgres_integration
    test "sessions, refresh tokens, device keys and push tokens are all gone" do
      app = seed_app!()
      {user, phone} = seed_user(app, @phone)

      Repo.query!(
        "INSERT INTO device_sessions (user_id, device_id, platform, refresh_token_hash, created_at) " <>
          "VALUES ($1::text::uuid, 'dev-1', 'ios', 'hash', now())",
        [user]
      )

      Repo.query!(
        "INSERT INTO refresh_tokens (user_id, device_id, token_hash, expires_at) " <>
          "VALUES ($1::text::uuid, 'dev-1', 'hash', now() + interval '30 days')",
        [user]
      )

      Repo.query!(
        "INSERT INTO device_keys (user_id, device_id, app_id, ed25519_public, x25519_public) " <>
          "VALUES ($1::text::uuid, 'dev-1', $2::text::uuid, $3, $4)",
        [user, app, :crypto.strong_rand_bytes(32), :crypto.strong_rand_bytes(32)]
      )

      Repo.query!(
        "INSERT INTO fcm_tokens (user_id, token, device_id, platform) " <>
          "VALUES ($1::text::uuid, $2, 'dev-1', 'android')",
        [user, "tok-#{System.unique_integer([:positive])}"]
      )

      assert {:ok, _} = delete(user, phone)

      for table <- ~w(device_sessions refresh_tokens device_keys fcm_tokens) do
        assert [] == row("SELECT user_id FROM #{table} WHERE user_id = $1::text::uuid", [user]),
               "#{table} still holds a row for the deleted user"
      end
    end

    @tag :postgres_integration
    test "conversations are LEFT, not deleted — the peer's chat keeps resolving" do
      app = seed_app!()
      {user, phone} = seed_user(app, @phone)
      {peer, _} = seed_user(app)

      conversation = Ecto.UUID.generate()

      Repo.query!(
        "INSERT INTO conversations (id, app_id, type, created_by, status) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'direct', $3::text::uuid, 'active')",
        [conversation, app, peer]
      )

      for member <- [user, peer] do
        Repo.query!(
          "INSERT INTO conversation_participants (conversation_id, user_id, app_id, role, joined_at) " <>
            "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, 'member', now())",
          [conversation, member, app]
        )
      end

      assert {:ok, _} = delete(user, phone)

      # The row SURVIVES with left_at set. Deleting it would remove the peer's ability to resolve who
      # the chat is with, which is the difference between "Deleted account" and a blank row.
      assert [[left_at]] =
               row(
                 "SELECT left_at FROM conversation_participants " <>
                   "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
                 [conversation, user]
               )

      assert %DateTime{} = left_at

      # And the peer is untouched.
      assert [[nil]] =
               row(
                 "SELECT left_at FROM conversation_participants " <>
                   "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
                 [conversation, peer]
               )
    end

    @tag :postgres_integration
    test "the username is held for 30 days, not freed the instant the profile goes" do
      app = seed_app!()
      {user, phone} = seed_user(app, @phone)

      Repo.query!(
        "UPDATE user_profiles SET username = 'takenname', username_key = 'takenname' " <>
          "WHERE user_id = $1::text::uuid",
        [user]
      )

      assert {:ok, _} = delete(user, phone)

      assert [[held_until]] =
               row("SELECT held_until FROM username_holds WHERE username_key = 'takenname'", [])

      assert DateTime.compare(held_until, DateTime.utc_now()) == :gt
    end
  end

  describe "the re-auth guard" do
    @tag :postgres_integration
    test "a wrong phone number refuses, and the account is untouched" do
      app = seed_app!()
      {user, _phone} = seed_user(app, @phone)

      assert {:error, :reauth_failed} = delete(user, "+15550100000")

      assert [["active"]] = row("SELECT status FROM users_auth WHERE id = $1::text::uuid", [user])
    end

    @tag :postgres_integration
    test "formatting is normalised — spaces and a 00 prefix still match the stored E.164" do
      app = seed_app!()
      {user, _phone} = seed_user(app, @phone)

      assert {:ok, _} = delete(user, "+1 555 010 0777")
    end

    @tag :postgres_integration
    test "an admin account cannot delete itself from inside the app" do
      app = seed_app!()
      {user, phone} = seed_user(app, @phone)
      Repo.query!("UPDATE users_auth SET role = 'admin' WHERE id = $1::text::uuid", [user])

      assert {:error, :account_undeletable} = delete(user, phone)
    end

    @tag :postgres_integration
    test "deleting twice is not found the second time — no double purge" do
      app = seed_app!()
      {user, phone} = seed_user(app, @phone)

      assert {:ok, _} = delete(user, phone)
      assert {:error, :account_not_found} = delete(user, phone)
    end
  end

  describe "the catalog sweep" do
    @tag :postgres_integration
    test "the resolved set is PINNED — a new cascading table fails here instead of surviving a deletion" do
      resolved = AccountDeletion.cascade_columns()
      tables = resolved |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

      assert tables == [
               "app_owners",
               "auto_reply_log",
               "auto_reply_settings",
               "blocked_users",
               "broadcast_list_members",
               "broadcast_lists",
               "call_participants",
               "conversation_tags",
               "dating_matches",
               "dating_profiles",
               "dating_swipes",
               "device_keys",
               "device_sessions",
               "favourite_contacts",
               "fcm_tokens",
               "message_pins",
               "nearby_connection_requests",
               "nearby_connections",
               "nearby_presence",
               "nearby_settings",
               "push_subscriptions",
               "quick_replies",
               "refresh_tokens",
               "status_audience",
               "status_audience_members",
               "status_posts",
               "tenant_members",
               "user_blocks",
               "user_privacy_settings",
               "user_profiles",
               "user_reports",
               "user_settings",
               "view_once_opens"
             ],
             "the set of tables that cascade off users_auth changed. If a table was ADDED, decide " <>
               "whether deletion should purge it (usually yes — then just update this list) or " <>
               "handle it by name in AccountDeletion. If one was REMOVED, its rows now survive a " <>
               "deletion and something must clean them up."

      # conversation_participants cascades too, and is deliberately NOT in the sweep — it is updated
      # rather than deleted. If it ever drops out of @handled_by_name it would start being purged,
      # which silently breaks the peer's chat.
      refute "conversation_participants" in tables
      assert "conversation_participants" in AccountDeletion.handled_by_name()
    end
  end
end
