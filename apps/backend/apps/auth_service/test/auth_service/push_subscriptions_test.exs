defmodule AuthService.PushSubscriptionsTest do
  use AuthService.DataCase, async: false

  # WHOLE-MODULE tag: DataCase's setup checks out a sandbox connection for EVERY test here, so even the
  # validation-only test needs the database once it lives in this suite. It was the one untagged test
  # in a DB suite — the source of the long-standing "PushSubscriptions flake": green when a local
  # Postgres happened to be up, a 6-second connection timeout when not.
  @moduletag :postgres_integration

  alias AuthService.PushSubscriptions
  alias AuthService.Repo

  @user_a "51111111-1111-4111-8111-111111111111"
  @user_b "52222222-2222-4222-8222-222222222222"
  @endpoint "https://fcm.googleapis.com/fcm/send/test-endpoint-1"

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
      [@user_a, "+915111111111", @user_b, "+915222222222"]
    )
  end

  defp count(endpoint) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM push_subscriptions WHERE endpoint = $1", [endpoint])

    n
  end

  test "save upserts by endpoint (re-subscribe updates keys + owner); delete is caller-scoped" do
    seed_users!()

    assert {:ok, %{saved: true}} =
             PushSubscriptions.save_subscription(%{
               "user_id" => @user_a,
               "endpoint" => @endpoint,
               "p256dh" => "key1",
               "auth" => "auth1",
               "device_id" => "web-aaaa"
             })

    assert count(@endpoint) == 1

    # Same browser re-subscribes under another account → same row, new owner/keys/device (still 1
    # row). The device linkage (103) follows the CURRENT session, so revocation targets the right one.
    assert {:ok, _} =
             PushSubscriptions.save_subscription(%{
               "user_id" => @user_b,
               "endpoint" => @endpoint,
               "p256dh" => "key2",
               "auth" => "auth2",
               "device_id" => "web-bbbb"
             })

    assert count(@endpoint) == 1

    %{rows: [[owner, p256dh, device_id]]} =
      Repo.query!(
        "SELECT user_id::text, p256dh, device_id FROM push_subscriptions WHERE endpoint = $1",
        [@endpoint]
      )

    assert owner == @user_b
    assert p256dh == "key2"
    assert device_id == "web-bbbb"

    # Delete scoped to the CALLER: user A (not the owner) can't remove it; user B can.
    assert {:ok, _} =
             PushSubscriptions.delete_subscription(%{
               "user_id" => @user_a,
               "endpoint" => @endpoint
             })

    assert count(@endpoint) == 1

    assert {:ok, _} =
             PushSubscriptions.delete_subscription(%{
               "user_id" => @user_b,
               "endpoint" => @endpoint
             })

    assert count(@endpoint) == 0
  end

  test "missing fields are rejected" do
    assert {:error, :invalid_request} =
             PushSubscriptions.save_subscription(%{"user_id" => @user_a, "endpoint" => ""})

    assert {:error, :invalid_request} =
             PushSubscriptions.delete_subscription(%{"user_id" => @user_a})
  end
end
