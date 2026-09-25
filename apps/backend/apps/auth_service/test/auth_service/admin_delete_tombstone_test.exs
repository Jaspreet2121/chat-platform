defmodule AuthService.AdminDeleteTombstoneTest do
  @moduledoc """
  An admin delete is the SAME deletion the person could have run themselves.

  Until 2026-09-25 it was not: the console path hard-deleted `users_auth` and moved every
  conversation the target had created onto the acting admin — `UPDATE conversations SET
  created_by = <admin>` — and the dialog said "reassigned to you". That is an admin being handed
  other people's private chats as a side effect of closing an account. This test seeds a
  conversation the target created with a peer in it, deletes the target from the console, and
  requires that the admin ended up with NOTHING: not the conversation, not a seat in it.
  """
  use AuthService.DataCase, async: false

  alias AuthService.Moderation

  @tenant "00000000-0000-0000-0000-000000000001"

  defp user!(role, opts \\ []) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status, role) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active', $4)",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}", role]
    )

    if username = Keyword.get(opts, :username) do
      Repo.query!(
        "INSERT INTO user_profiles (user_id, app_id, display_name, username, username_key) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, $3, $4, lower($4))",
        [id, @tenant, "Person #{username}", username]
      )
    end

    id
  end

  defp conversation!(creator, members) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid)",
      [id, @tenant, creator]
    )

    for member <- members do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id) " <>
          "VALUES ($1::text::uuid, $2::text::uuid)",
        [id, member]
      )
    end

    id
  end

  defp scalar(sql, params) do
    %Postgrex.Result{rows: [[value]]} = Repo.query!(sql, params)
    value
  end

  @tag :postgres_integration
  test "the admin ends up with nothing: no conversation, no seat, and the target is a tombstone" do
    admin = user!("root")
    target = user!("user", username: "leaving#{System.unique_integer([:positive])}")
    peer = user!("user")
    conversation = conversation!(target, [target, peer])

    assert {:ok, %{user_id: ^target, deleted: true}} =
             Moderation.delete_user(%{
               "user_id" => target,
               "actor_user_id" => admin,
               "app_id" => @tenant
             })

    # THE CONVERSATION WAS NOT REASSIGNED. created_by still names the (tombstoned) target.
    assert scalar("SELECT created_by::text FROM conversations WHERE id = $1::text::uuid", [
             conversation
           ]) == target

    # THE ADMIN IS NOT A PARTICIPANT of anything the target was in.
    assert scalar(
             "SELECT count(*) FROM conversation_participants WHERE user_id = $1::text::uuid",
             [admin]
           ) == 0

    # The target LEFT, the peer stayed — so the peer's client can still say who it was with.
    assert scalar(
             "SELECT count(*) FROM conversation_participants " <>
               "WHERE user_id = $1::text::uuid AND left_at IS NOT NULL",
             [target]
           ) == 1

    assert scalar(
             "SELECT count(*) FROM conversation_participants " <>
               "WHERE user_id = $1::text::uuid AND left_at IS NULL",
             [peer]
           ) == 1

    # A TOMBSTONE, not a hole: the row exists, closed, identity scrubbed.
    %Postgrex.Result{rows: [[status, deleted_at, phone]]} =
      Repo.query!(
        "SELECT status, deleted_at, phone_number FROM users_auth WHERE id = $1::text::uuid",
        [target]
      )

    assert status == "deleted"
    refute is_nil(deleted_at)
    assert is_nil(phone)
  end

  @tag :postgres_integration
  test "the username is held for 30 days, the same hold self-serve writes" do
    admin = user!("root")
    handle = "held#{System.unique_integer([:positive])}"
    target = user!("user", username: handle)

    {:ok, _} =
      Moderation.delete_user(%{
        "user_id" => target,
        "actor_user_id" => admin,
        "app_id" => @tenant
      })

    %Postgrex.Result{rows: [[days]]} =
      Repo.query!(
        "SELECT round(extract(epoch FROM (held_until - now())) / 86400) " <>
          "FROM username_holds WHERE username_key = lower($1)",
        [handle]
      )

    assert Decimal.to_integer(days) == 30
  end

  @tag :postgres_integration
  test "it is audited as a tombstone, and a tombstone cannot be deleted twice" do
    admin = user!("root")
    target = user!("user")

    {:ok, _} =
      Moderation.delete_user(%{
        "user_id" => target,
        "actor_user_id" => admin,
        "app_id" => @tenant
      })

    %Postgrex.Result{rows: [[policy]]} =
      Repo.query!(
        "SELECT metadata->>'policy' FROM audit_logs WHERE action = 'user.delete' AND target_id = $1",
        [target]
      )

    assert policy == "tombstone"

    # A second delete must not write a second audit row claiming to have deleted somebody.
    assert Moderation.delete_user(%{
             "user_id" => target,
             "actor_user_id" => admin,
             "app_id" => @tenant
           }) == {:error, :user_not_found}
  end

  @tag :postgres_integration
  test "the console guards still hold: not yourself, not a root or admin" do
    admin = user!("root")
    other_admin = user!("admin")

    assert Moderation.delete_user(%{
             "user_id" => admin,
             "actor_user_id" => admin,
             "app_id" => @tenant
           }) ==
             {:error, :cannot_delete_self}

    assert Moderation.delete_user(%{
             "user_id" => other_admin,
             "actor_user_id" => admin,
             "app_id" => @tenant
           }) == {:error, :cannot_delete_privileged}
  end
end
