defmodule AuthService.FcmTokensApnsTest do
  @moduledoc """
  THE TOKEN STORE AFTER iOS (129). `fcm_tokens` held one row per (user, device) — true while Android
  was the only handset. An iPhone registers TWO credentials for one device: an alert token
  addressing com.growblic.exway and a VoIP token addressing com.growblic.exway.voip. Under the old
  key the second registration UPDATED the first and the account kept whichever the app happened to
  register last — messages arriving and calls not ringing, or the reverse, with nothing logged.
  """
  use AuthService.DataCase, async: false

  alias AuthService.FcmTokens

  @tenant "00000000-0000-0000-0000-000000000001"

  setup do
    # FcmTokens rides the SESSION persistence flag (AuthService.Sessions.persistence_enabled?/0) —
    # without it upsert_token/1 answers {:ok, %{saved: true}} and writes nothing, which is exactly
    # how the first run of this file asserted against an empty table.
    previous = Application.get_env(:auth_service, :session_persistence, false)
    Application.put_env(:auth_service, :session_persistence, true)
    on_exit(fn -> Application.put_env(:auth_service, :session_persistence, previous) end)
    :ok
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active', now(), now())",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp save(user_id, extra) do
    FcmTokens.upsert_token(
      Map.merge(
        %{
          "user_id" => user_id,
          "device_id" => "iphone-1",
          "token" => "tok-#{System.unique_integer([:positive])}"
        },
        extra
      )
    )
  end

  defp rows(user_id) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        "SELECT platform, kind, environment FROM fcm_tokens WHERE user_id = $1::text::uuid ORDER BY kind",
        [user_id]
      )

    rows
  end

  @tag :postgres_integration
  test "one iPhone keeps BOTH an alert and a VoIP token — they are different credentials" do
    user = user!()

    assert {:ok, _} =
             save(user, %{"platform" => "ios", "kind" => "alert", "environment" => "production"})

    assert {:ok, _} =
             save(user, %{"platform" => "ios", "kind" => "voip", "environment" => "production"})

    assert rows(user) == [
             ["ios", "alert", "production"],
             ["ios", "voip", "production"]
           ]
  end

  @tag :postgres_integration
  test "an Android re-registration still UPSERTS to one row — NULL kinds must not multiply" do
    user = user!()

    for _ <- 1..3, do: assert({:ok, _} = save(user, %{"platform" => "android"}))

    # NULLs are DISTINCT in a unique btree, so a bare (user, device, kind) index would have made
    # every re-registration a new row and the fan-out would send one push per historical one.
    assert rows(user) == [["android", nil, nil]]
  end

  @tag :postgres_integration
  test "re-registering the SAME channel replaces that channel's token and leaves the other alone" do
    user = user!()

    assert {:ok, _} =
             save(user, %{"platform" => "ios", "kind" => "alert", "environment" => "sandbox"})

    assert {:ok, _} =
             save(user, %{"platform" => "ios", "kind" => "voip", "environment" => "sandbox"})

    assert {:ok, _} =
             save(user, %{"platform" => "ios", "kind" => "alert", "environment" => "production"})

    assert rows(user) == [
             ["ios", "alert", "production"],
             ["ios", "voip", "sandbox"]
           ]
  end

  @tag :postgres_integration
  test "kind and environment are iOS-only, and an unknown value never reaches the column" do
    android = user!()
    ios = user!()

    # A kind on an Android registration is dropped — the column would invent a distinction the FCM
    # sender does not have.
    assert {:ok, _} =
             save(android, %{
               "platform" => "android",
               "kind" => "voip",
               "environment" => "sandbox"
             })

    assert rows(android) == [["android", nil, nil]]

    # An iOS registration with a junk kind falls back to `alert`, the channel an app registers
    # first — refusing it outright would leave a handset with no push at all.
    assert {:ok, _} =
             save(ios, %{"platform" => "ios", "kind" => "nonsense", "environment" => "nonsense"})

    assert rows(ios) == [["ios", "alert", "production"]]
  end
end
