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
    # PIN the mode this test is NAMED for. persistence_enabled? is global app env, so this test used
    # to inherit whatever the previously-run suite left behind — and with persistence ON,
    # create_invite DELIBERATELY reuses the pending invite for the same (inviter, phone) pair, making
    # all 20 codes identical. That is correct product behaviour and a broken test: it flaked purely on
    # suite ordering (the participant_events class of bug).
    prev = Application.get_env(:auth_service, :session_persistence)
    Application.put_env(:auth_service, :session_persistence, false)

    on_exit(fn ->
      if prev == nil,
        do: Application.delete_env(:auth_service, :session_persistence),
        else: Application.put_env(:auth_service, :session_persistence, prev)
    end)

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
