defmodule AuthService.FcmTokensTest do
  use AuthService.DataCase, async: false

  alias AuthService.FcmTokens
  alias AuthService.Repo

  @user_a "61111111-1111-4111-8111-111111111111"
  @user_b "62222222-2222-4222-8222-222222222222"
  @token "fcm-registration-token-aaaaaaaaaaaaaaaaaaaa"
  @other_token "fcm-registration-token-bbbbbbbbbbbbbbbbbbbb"

  setup do
    previous = Application.get_env(:auth_service, :session_persistence, false)
    Application.put_env(:auth_service, :session_persistence, true)
    on_exit(fn -> Application.put_env(:auth_service, :session_persistence, previous) end)
    :ok
  end

  defp seed_users! do
    Repo.query!(
      "INSERT INTO users_auth (id, phone_number) VALUES ($1::text::uuid, $2), ($3::text::uuid, $4) " <>
        "ON CONFLICT DO NOTHING",
      [@user_a, "+916111111111", @user_b, "+916222222222"]
    )
  end

  defp count(token) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM fcm_tokens WHERE token = $1", [token])
    n
  end

  defp rows_for_device(user_id, device_id) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM fcm_tokens WHERE user_id = $1::text::uuid AND device_id = $2",
        [user_id, device_id]
      )

    n
  end

  defp token_of(user_id, device_id) do
    %{rows: [[token]]} =
      Repo.query!(
        "SELECT token FROM fcm_tokens WHERE user_id = $1::text::uuid AND device_id = $2",
        [user_id, device_id]
      )

    token
  end

  # --- ONE ROW PER DEVICE (121) --------------------------------------------------------------------

  @tag :postgres_integration
  test "a ROTATED token for the same device UPDATES its row — never a second one" do
    seed_users!()

    {:ok, _} =
      FcmTokens.upsert_token(%{"user_id" => @user_a, "token" => @token, "device_id" => "pixel-8"})

    # FCM rotated the registration token (reinstall, data clear, SDK refresh): same handset, new
    # token. This is exactly what produced three rows for one phone in production.
    assert {:ok, %{saved: true}} =
             FcmTokens.upsert_token(%{
               "user_id" => @user_a,
               "token" => @other_token,
               "device_id" => "pixel-8"
             })

    assert rows_for_device(@user_a, "pixel-8") == 1,
           "the device holds more than one row — every rotation adds a corpse that is re-sent to " <>
             "on every message until FCM 404s it"

    assert token_of(@user_a, "pixel-8") == @other_token
    # The rotated-away token is gone, not orphaned.
    assert count(@token) == 0
  end

  @tag :postgres_integration
  test "a token MOVING to a new device id on the same account succeeds — token stays UNIQUE" do
    seed_users!()

    {:ok, _} =
      FcmTokens.upsert_token(%{"user_id" => @user_a, "token" => @token, "device_id" => "old-id"})

    # The app minted a fresh device id (uninstall / pm clear) but FCM handed back the same token.
    # UNIQUE(token) would make a naive device-keyed insert blow up here.
    assert {:ok, %{saved: true}} =
             FcmTokens.upsert_token(%{
               "user_id" => @user_a,
               "token" => @token,
               "device_id" => "new-id"
             }),
           "a token arriving under a new device id was refused — the handset can never re-register"

    assert count(@token) == 1
    assert rows_for_device(@user_a, "old-id") == 0
    assert token_of(@user_a, "new-id") == @token
  end

  @tag :postgres_integration
  test "device_id is REQUIRED — a row that names no device can never be updated or revoked" do
    seed_users!()

    assert {:error, :invalid_request} =
             FcmTokens.upsert_token(%{"user_id" => @user_a, "token" => @token})

    assert {:error, :invalid_request} =
             FcmTokens.upsert_token(%{"user_id" => @user_a, "token" => @token, "device_id" => ""})

    assert count(@token) == 0
  end

  @tag :postgres_integration
  test "the (user_id, device_id, kind) key is enforced by the SCHEMA, not only by the upsert" do
    seed_users!()

    Repo.query!(
      "INSERT INTO fcm_tokens (user_id, token, device_id) VALUES ($1::text::uuid, $2, $3)",
      [@user_a, @token, "pixel-8"]
    )

    # A second row for the same device AND CHANNEL, written around the upsert, is refused by the
    # index. 129 widened the key from (user, device) to (user, device, COALESCE(kind, '')) because an
    # iPhone registers two credentials for one device; both rows here have kind NULL, so they still
    # collide exactly as they did before.
    assert_raise Postgrex.Error, ~r/fcm_tokens_user_device_kind_key/, fn ->
      Repo.query!(
        "INSERT INTO fcm_tokens (user_id, token, device_id) VALUES ($1::text::uuid, $2, $3)",
        [@user_a, @other_token, "pixel-8"]
      )
    end

    # ...and a NULL device is refused outright.
    assert_raise Postgrex.Error, ~r/not-null|null value/, fn ->
      Repo.query!(
        "INSERT INTO fcm_tokens (user_id, token) VALUES ($1::text::uuid, $2)",
        [@user_a, "third-token"]
      )
    end
  end

  @tag :postgres_integration
  test "upsert is by DEVICE; a re-sign-in on the same handset MOVES the row to the new account" do
    seed_users!()

    assert {:ok, %{saved: true}} =
             FcmTokens.upsert_token(%{
               "user_id" => @user_a,
               "token" => @token,
               "device_id" => "pixel-8"
             })

    assert count(@token) == 1

    # The same handset signs in as somebody else and re-registers its SAME token. One row still,
    # now owned by B — otherwise the phone would keep receiving A's messages after the switch.
    assert {:ok, _} =
             FcmTokens.upsert_token(%{
               "user_id" => @user_b,
               "token" => @token,
               "device_id" => "pixel-8"
             })

    assert count(@token) == 1

    %{rows: [[owner, device, platform]]} =
      Repo.query!(
        "SELECT user_id::text, device_id, platform FROM fcm_tokens WHERE token = $1",
        [@token]
      )

    assert owner == @user_b
    assert device == "pixel-8"
    assert platform == "android"
  end

  @tag :postgres_integration
  test "tokens_for_user returns every device the user registered, and nothing else" do
    seed_users!()

    {:ok, _} =
      FcmTokens.upsert_token(%{"user_id" => @user_a, "token" => @token, "device_id" => "a-1"})

    {:ok, _} =
      FcmTokens.upsert_token(%{
        "user_id" => @user_a,
        "token" => @other_token,
        "device_id" => "a-2"
      })

    {:ok, _} =
      FcmTokens.upsert_token(%{
        "user_id" => @user_b,
        "token" => "someone-elses-token",
        "device_id" => "b-1"
      })

    assert Enum.sort(FcmTokens.tokens_for_user(@user_a)) == Enum.sort([@token, @other_token])
    assert FcmTokens.tokens_for_user(@user_b) == ["someone-elses-token"]
    assert FcmTokens.tokens_for_user("63333333-3333-4333-8333-333333333333") == []
  end

  @tag :postgres_integration
  test "delete is caller-scoped; pruning by token value is not" do
    seed_users!()

    {:ok, _} =
      FcmTokens.upsert_token(%{"user_id" => @user_a, "token" => @token, "device_id" => "a-1"})

    # Someone else cannot unregister A's device.
    assert {:ok, _} = FcmTokens.delete_token(%{"user_id" => @user_b, "token" => @token})
    assert count(@token) == 1

    assert {:ok, _} = FcmTokens.delete_token(%{"user_id" => @user_a, "token" => @token})
    assert count(@token) == 0

    # Pruning is deliberately NOT user-scoped: a token FCM has declared dead is dead for whoever
    # happens to own it right now.
    {:ok, _} =
      FcmTokens.upsert_token(%{
        "user_id" => @user_b,
        "token" => @other_token,
        "device_id" => "b-1"
      })

    assert {:ok, %{deleted: 1}} = FcmTokens.delete_tokens([@other_token])
    assert count(@other_token) == 0
  end

  @tag :postgres_integration
  test "an unknown platform falls back to android rather than storing client input" do
    seed_users!()

    {:ok, _} =
      FcmTokens.upsert_token(%{
        "user_id" => @user_a,
        "token" => @token,
        "device_id" => "a-1",
        "platform" => "'; DROP--"
      })

    %{rows: [[platform]]} =
      Repo.query!("SELECT platform FROM fcm_tokens WHERE token = $1", [@token])

    assert platform == "android"
  end
end
