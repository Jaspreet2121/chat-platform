defmodule SharedInfra.AvatarTokenTest do
  @moduledoc """
  The avatar capability token: bound to (user_id, app_id, kind: avatar), signed + expiry, timing-safe.
  """
  use ExUnit.Case, async: false

  alias SharedInfra.AvatarToken

  # Mirror the module's salt + secret source so we can craft adversarial tokens (expired / wrong-kind).
  @salt "avatar-icon-capability-v1"

  setup do
    prev = System.get_env("SECRET_KEY_BASE")

    System.put_env(
      "SECRET_KEY_BASE",
      "test_secret_key_base_deterministic_at_least_sixty_four_chars_long_x"
    )

    on_exit(fn ->
      if prev,
        do: System.put_env("SECRET_KEY_BASE", prev),
        else: System.delete_env("SECRET_KEY_BASE")
    end)

    :ok
  end

  defp secret, do: System.get_env("SECRET_KEY_BASE")

  test "a freshly signed token verifies back to its bound (user_id, app_id)" do
    token = AvatarToken.sign("user-a", "app-x")
    assert {:ok, %{user_id: "user-a", app_id: "app-x"}} = AvatarToken.verify(token)
  end

  test "a token for one user does not decode as another (the payload IS the binding)" do
    a = AvatarToken.sign("user-a", "app-x")
    b = AvatarToken.sign("user-b", "app-x")
    assert {:ok, %{user_id: "user-a"}} = AvatarToken.verify(a)
    assert {:ok, %{user_id: "user-b"}} = AvatarToken.verify(b)
    refute a == b
  end

  test "a tampered token → :error" do
    token = AvatarToken.sign("user-a", "app-x")
    tampered = tamper(token)
    assert AvatarToken.verify(tampered) == :error
  end

  test "an expired token → :error (expiry is inside the signed payload)" do
    eight_days_ago = System.os_time(:second) - 8 * 24 * 60 * 60

    expired =
      Plug.Crypto.sign(secret(), @salt, %{"u" => "user-a", "a" => "app-x", "k" => "avatar"},
        signed_at: eight_days_ago
      )

    assert AvatarToken.verify(expired) == :error
  end

  test "a token with kind != avatar → :error (scope claim enforced)" do
    wrong_kind =
      Plug.Crypto.sign(secret(), @salt, %{"u" => "user-a", "a" => "app-x", "k" => "message"})

    assert AvatarToken.verify(wrong_kind) == :error
  end

  test "a token signed under a DIFFERENT secret → :error (rotation invalidates)" do
    other =
      Plug.Crypto.sign("a_totally_different_secret_key_base_value_also_long_enough_x", @salt, %{
        "u" => "user-a",
        "a" => "app-x",
        "k" => "avatar"
      })

    assert AvatarToken.verify(other) == :error
  end

  test "garbage / empty / non-binary → :error" do
    assert AvatarToken.verify("not-a-token") == :error
    assert AvatarToken.verify("") == :error
    assert AvatarToken.verify(nil) == :error
  end

  # TAMPER A MIDDLE BYTE — NEVER THE LAST ONE. The token's trailing base64 character encodes only
  # the final 2-4 significant bits plus SLACK: several distinct characters decode to the same bytes,
  # so flipping the last character often produces a byte-identical payload that verifies as GENUINE.
  # Measured on this codebase: 19/300 last-character flips verified successfully, 0/300 for a middle
  # character. A security test that intermittently passes a forgery is worse than no test — do not
  # move this back to String.last/1.
  defp tamper(token) do
    index = div(String.length(token), 2)
    replacement = if String.at(token, index) == "a", do: "b", else: "a"
    String.slice(token, 0, index) <> replacement <> String.slice(token, (index + 1)..-1//1)
  end
end
