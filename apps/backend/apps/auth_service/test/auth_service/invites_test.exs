defmodule AuthService.InvitesTest do
  use ExUnit.Case, async: false

  alias AuthService.Invites

  # Persistence-off path (test/dev default): a random, URL-safe code with no tracking row.
  test "create_invite returns a url-safe invite code" do
    assert {:ok, %{invite_code: code}} =
             Invites.create_invite(%{
               "inviter_user_id" => "11111111-1111-4111-8111-111111111111",
               "invited_phone" => "+919876543210"
             })

    assert is_binary(code)
    # 7 random bytes → 12 chars of lowercase base32 (deep-link friendly: no padding/specials)
    assert String.match?(code, ~r/^[a-z2-7]{12}$/)
  end

  test "create_invite requires inviter and phone" do
    assert {:error, :invalid_request} = Invites.create_invite(%{"invited_phone" => "+91987"})
    assert {:error, :invalid_request} = Invites.create_invite(%{"inviter_user_id" => "u"})

    assert {:error, :invalid_request} =
             Invites.create_invite(%{"inviter_user_id" => "", "invited_phone" => ""})
  end

  test "codes are unique per call (stateless path)" do
    codes =
      for _ <- 1..20 do
        {:ok, %{invite_code: code}} =
          Invites.create_invite(%{
            "inviter_user_id" => "11111111-1111-4111-8111-111111111111",
            "invited_phone" => "+919876543210"
          })

        code
      end

    assert length(Enum.uniq(codes)) == 20
  end
end
