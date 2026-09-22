defmodule SharedInfra.Apns.ProviderTokenTest do
  @moduledoc """
  The APNs provider token, driven with a THROWAWAY P-256 key generated in the test. No Apple key is
  needed to prove the thing that actually goes wrong: a JWT that is well-formed but whose signature
  Apple will not accept comes back as `InvalidProviderToken` with nothing saying which half is wrong.

  So this verifies the signature the way Apple does — against the public key, over the exact signing
  input — and pins the DER-to-raw conversion, which is the one step with a wrong answer that still
  produces a plausible-looking token.
  """
  use ExUnit.Case, async: true

  alias SharedInfra.Apns.ProviderToken

  @key_id "ABC123DEFG"
  @team_id "TEAM123456"

  setup do
    # A real P-256 key. Apple ships a PKCS#8 `.p8`; OTP writes an SEC1 "EC PRIVATE KEY" PEM. Both
    # decode through the same `pem_decode` + `pem_entry_decode` pair the signer uses, which is the
    # property under test — the container reads whatever file it is given.
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    der = :public_key.der_encode(:ECPrivateKey, key)
    pem = :public_key.pem_encode([{:ECPrivateKey, der, :not_encrypted}])

    # elem/2 rather than a record match: ECPrivateKey is {:ECPrivateKey, version, private, params,
    # public, attrs}. The public field is the raw uncompressed point (0x04 || X || Y), which is
    # exactly what :crypto.verify/5 wants.
    public = elem(key, 4)

    {:ok, pem: pem, public: public}
  end

  defp parts(jwt), do: String.split(jwt, ".")

  defp decode(segment) do
    segment |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  test "the header carries kid and the payload carries iss — Apple checks both, in those places",
       %{pem: pem} do
    assert {:ok, jwt} = ProviderToken.sign(pem, @key_id, @team_id, 1_700_000_000)
    assert [header, payload, _signature] = parts(jwt)

    assert decode(header) == %{"alg" => "ES256", "kid" => @key_id, "typ" => "JWT"}
    assert decode(payload) == %{"iss" => @team_id, "iat" => 1_700_000_000}
  end

  test "the signature VERIFIES against the public key over the signing input", %{
    pem: pem,
    public: public
  } do
    assert {:ok, jwt} = ProviderToken.sign(pem, @key_id, @team_id, 1_700_000_000)
    assert [header, payload, signature] = parts(jwt)

    raw = Base.url_decode64!(signature, padding: false)

    # RFC 7518: raw R||S, 32 bytes each for P-256. A DER signature here is 70-72 bytes and would be
    # accepted by nothing — the length assertion is the cheap half of the check.
    assert byte_size(raw) == 64

    <<r::binary-size(32), s::binary-size(32)>> = raw

    der =
      :public_key.der_encode(
        :"ECDSA-Sig-Value",
        {:"ECDSA-Sig-Value", :binary.decode_unsigned(r), :binary.decode_unsigned(s)}
      )

    assert :crypto.verify(
             :ecdsa,
             :sha256,
             header <> "." <> payload,
             der,
             [public, :secp256r1]
           )
  end

  test "a signature whose r or s needs padding still verifies — the leading-zero case", %{
    pem: pem
  } do
    # DER drops leading zero bytes and adds one to keep an integer positive, so r and s are 31-33
    # bytes before conversion. Signing repeatedly walks through those cases; every one must produce
    # exactly 64 raw bytes.
    for iat <- 1..40 do
      assert {:ok, jwt} = ProviderToken.sign(pem, @key_id, @team_id, iat)
      [_header, _payload, signature] = parts(jwt)
      assert byte_size(Base.url_decode64!(signature, padding: false)) == 64
    end
  end

  test "an unreadable or malformed key is an error, never a crash and never a logged key" do
    assert {:error, :apns_token_signing_failed} =
             ProviderToken.sign("not a pem at all", @key_id, @team_id)
  end

  test "with no Apple key configured the sender is simply OFF" do
    for var <- ~w(APNS_KEY_PATH APNS_KEY_ID APNS_TEAM_ID), do: System.delete_env(var)

    ProviderToken.reset()
    refute ProviderToken.configured?()
    assert {:error, :apns_not_configured} = ProviderToken.fetch()
    assert {:error, :apns_not_configured} = ProviderToken.team_id()
  end
end
