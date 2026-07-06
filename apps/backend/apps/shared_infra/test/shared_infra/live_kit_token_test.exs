defmodule SharedInfra.LiveKitTokenTest do
  use ExUnit.Case, async: false

  alias SharedInfra.LiveKitToken

  @key "APItestkey123"
  @secret "test-livekit-secret-0123456789abcdef"

  setup do
    previous = Application.get_env(:shared_infra, :livekit)

    Application.put_env(:shared_infra, :livekit,
      api_key: @key,
      api_secret: @secret,
      url: "wss://livekit.test"
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:shared_infra, :livekit, previous)
      else
        Application.delete_env(:shared_infra, :livekit)
      end
    end)

    :ok
  end

  test "mints an HS256 JWT whose signature verifies against LIVEKIT_API_SECRET (what LiveKit does)" do
    now = 1_700_000_000
    {:ok, jwt} = LiveKitToken.create("user-1", "room-abc", name: "Alice", now: now, ttl_seconds: 600)

    assert [header_b64, claims_b64, signature_b64] = String.split(jwt, ".")

    # Header is the standard HS256 JWS header.
    header = header_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()
    assert header == %{"alg" => "HS256", "typ" => "JWT"}

    # THE proof: recompute the HMAC-SHA256 over header.claims with the API secret and compare — this is
    # exactly the verification LiveKit's server performs. If it matches, LiveKit will accept the token.
    expected_sig =
      :crypto.mac(:hmac, :sha256, @secret, header_b64 <> "." <> claims_b64)
      |> Base.url_encode64(padding: false)

    assert signature_b64 == expected_sig

    # A wrong secret must NOT verify.
    wrong_sig =
      :crypto.mac(:hmac, :sha256, "not-the-secret", header_b64 <> "." <> claims_b64)
      |> Base.url_encode64(padding: false)

    refute signature_b64 == wrong_sig

    # Claims match LiveKit's spec (iss=key, sub=identity, name, iat/nbf/exp, video grant).
    claims = claims_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()
    assert claims["iss"] == @key
    assert claims["sub"] == "user-1"
    assert claims["name"] == "Alice"
    assert claims["iat"] == now
    assert claims["nbf"] == now
    assert claims["exp"] == now + 600

    assert claims["video"] == %{
             "room" => "room-abc",
             "roomJoin" => true,
             "canPublish" => true,
             "canSubscribe" => true
           }
  end

  test "name defaults to the identity when not given" do
    {:ok, jwt} = LiveKitToken.create("user-42", "room-1")
    claims = jwt |> String.split(".") |> Enum.at(1) |> Base.url_decode64!(padding: false) |> Jason.decode!()
    assert claims["sub"] == "user-42"
    assert claims["name"] == "user-42"
  end

  test "url/0 returns the configured LiveKit URL" do
    assert LiveKitToken.url() == "wss://livekit.test"
  end

  test "errors cleanly when key/secret are not configured (no crash → 503 at the edge)" do
    Application.put_env(:shared_infra, :livekit, api_key: nil, api_secret: nil, url: nil)
    assert {:error, :livekit_not_configured} = LiveKitToken.create("user-1", "room-1")
    refute LiveKitToken.configured?()
  end
end
