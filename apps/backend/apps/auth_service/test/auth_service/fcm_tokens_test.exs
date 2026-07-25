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

  @tag :postgres_integration
  test "upsert is by token; re-registering MOVES the device to the new account" do
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

    {:ok, _} = FcmTokens.upsert_token(%{"user_id" => @user_a, "token" => @token})
    {:ok, _} = FcmTokens.upsert_token(%{"user_id" => @user_a, "token" => @other_token})
    {:ok, _} = FcmTokens.upsert_token(%{"user_id" => @user_b, "token" => "someone-elses-token"})

    assert Enum.sort(FcmTokens.tokens_for_user(@user_a)) == Enum.sort([@token, @other_token])
    assert FcmTokens.tokens_for_user(@user_b) == ["someone-elses-token"]
    assert FcmTokens.tokens_for_user("63333333-3333-4333-8333-333333333333") == []
  end

  @tag :postgres_integration
  test "delete is caller-scoped; pruning by token value is not" do
    seed_users!()
    {:ok, _} = FcmTokens.upsert_token(%{"user_id" => @user_a, "token" => @token})

    # Someone else cannot unregister A's device.
    assert {:ok, _} = FcmTokens.delete_token(%{"user_id" => @user_b, "token" => @token})
    assert count(@token) == 1

    assert {:ok, _} = FcmTokens.delete_token(%{"user_id" => @user_a, "token" => @token})
    assert count(@token) == 0

    # Pruning is deliberately NOT user-scoped: a token FCM has declared dead is dead for whoever
    # happens to own it right now.
    {:ok, _} = FcmTokens.upsert_token(%{"user_id" => @user_b, "token" => @other_token})
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
        "platform" => "'; DROP--"
      })

    %{rows: [[platform]]} =
      Repo.query!("SELECT platform FROM fcm_tokens WHERE token = $1", [@token])

    assert platform == "android"
  end
end
