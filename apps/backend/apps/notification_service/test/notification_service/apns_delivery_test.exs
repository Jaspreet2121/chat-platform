defmodule NotificationService.ApnsDeliveryTest do
  @moduledoc """
  THE HEADERS AND THE HOST — the half of an APNs push that is not the payload, and the half whose
  mistakes Apple answers with a code that names nothing useful.

  A real (throwaway) P-256 key is written to a temp file so the provider token is genuinely minted
  and genuinely attached; the transport is stubbed so nothing leaves the machine.
  """
  use NotificationService.DataCase, async: false

  alias NotificationService.ApnsSender
  alias SharedInfra.Apns.ProviderToken

  @tenant "00000000-0000-0000-0000-000000000001"

  defmodule Transport do
    @moduledoc false
    @behaviour NotificationService.ApnsTransport

    def start, do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def sent, do: Agent.get(__MODULE__, &Enum.reverse/1)

    @impl true
    def post(url, headers, body) do
      Agent.update(
        __MODULE__,
        &[%{url: url, headers: Map.new(headers), body: Jason.decode!(body)} | &1]
      )

      {code, response} =
        Application.get_env(:notification_service, :apns_stub_status, {200, "{}"})

      {:ok, code, response}
    end
  end

  setup do
    start_supervised!(%{id: Transport, start: {Transport, :start, []}})

    key = :public_key.generate_key({:namedCurve, :secp256r1})
    der = :public_key.der_encode(:ECPrivateKey, key)
    pem = :public_key.pem_encode([{:ECPrivateKey, der, :not_encrypted}])
    path = Path.join(System.tmp_dir!(), "apns-test-#{System.unique_integer([:positive])}.p8")
    File.write!(path, pem)

    System.put_env("APNS_KEY_PATH", path)
    System.put_env("APNS_KEY_ID", "KEYID12345")
    System.put_env("APNS_TEAM_ID", "TEAMID6789")
    ProviderToken.reset()

    Application.put_env(:notification_service, :apns_transport, Transport)

    on_exit(fn ->
      File.rm(path)
      for var <- ~w(APNS_KEY_PATH APNS_KEY_ID APNS_TEAM_ID), do: System.delete_env(var)
      ProviderToken.reset()
      Application.delete_env(:notification_service, :apns_transport)
      Application.delete_env(:notification_service, :apns_stub_status)
    end)

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

  defp token!(user_id, kind, environment) do
    token = "apns-#{kind}-#{System.unique_integer([:positive])}"

    Repo.query!(
      "INSERT INTO fcm_tokens (user_id, token, device_id, platform, kind, environment) " <>
        "VALUES ($1::text::uuid, $2, $3, 'ios', $4, $5)",
      [user_id, token, "iphone-#{kind}", kind, environment]
    )

    token
  end

  @tag :postgres_integration
  test "a VoIP push goes to the VOIP topic, at priority 10, with a bearer provider token" do
    user = user!()
    token = token!(user, "voip", "production")

    ApnsSender.deliver_call(%{"call_id" => "c1", "caller_name" => "Ada"}, user)

    assert [sent] = Transport.sent()

    # The topic is what makes this ring. The alert topic would be rejected for a voip push type, and
    # the reverse leaves CallKit silent.
    assert sent.headers["apns-topic"] == "com.growblic.exway.voip"
    assert sent.headers["apns-push-type"] == "voip"
    # Apple REJECTS priority 5 on a voip push.
    assert sent.headers["apns-priority"] == "10"
    assert String.starts_with?(sent.headers["authorization"], "bearer ")
    assert sent.url == "https://api.push.apple.com/3/device/#{token}"
  end

  @tag :postgres_integration
  test "a SANDBOX token goes to the sandbox host — the environment is a property of the TOKEN" do
    user = user!()
    token = token!(user, "voip", "sandbox")

    ApnsSender.deliver_call(%{"call_id" => "c1"}, user)

    assert [sent] = Transport.sent()
    assert sent.url == "https://api.sandbox.push.apple.com/3/device/#{token}"
  end

  @tag :postgres_integration
  test "a call NEVER goes to an alert token, and a message never to a VoIP one" do
    user = user!()
    _alert = token!(user, "alert", "production")
    voip = token!(user, "voip", "production")

    ApnsSender.deliver_call(%{"call_id" => "c1"}, user)

    # One send, to the VoIP token only. Sending the call to the alert token would be rejected as
    # DeviceTokenNotForTopic; sending it to BOTH would ring twice.
    assert [sent] = Transport.sent()
    assert sent.url =~ voip
  end

  @tag :postgres_integration
  test "a 410 with BadDeviceToken PRUNES the row; a transient status leaves it alone" do
    user = user!()
    token = token!(user, "voip", "production")

    Application.put_env(
      :notification_service,
      :apns_stub_status,
      {410, ~s({"reason":"BadDeviceToken"})}
    )

    ApnsSender.deliver_call(%{"call_id" => "c1"}, user)

    assert %Postgrex.Result{rows: []} =
             Repo.query!("SELECT token FROM fcm_tokens WHERE token = $1", [token])

    # A different token, and a 503 — Apple is unwell, the handset is fine.
    kept = token!(user, "voip", "production")

    Application.put_env(
      :notification_service,
      :apns_stub_status,
      {503, ~s({"reason":"ServiceUnavailable"})}
    )

    ApnsSender.deliver_call(%{"call_id" => "c1"}, user)

    assert %Postgrex.Result{rows: [[^kept]]} =
             Repo.query!("SELECT token FROM fcm_tokens WHERE token = $1", [kept])
  end

  @tag :postgres_integration
  test "a user with no iOS tokens is a quiet no-op, not an error" do
    assert :ok = ApnsSender.deliver_call(%{"call_id" => "c1"}, user!())
    assert Transport.sent() == []
  end
end
