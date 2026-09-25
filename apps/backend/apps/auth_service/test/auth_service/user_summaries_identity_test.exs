defmodule AuthService.UserSummariesIdentityTest do
  @moduledoc """
  The batched identity lookup every admin list resolves names through carries the HANDLE, not just
  the display name. The console's rule is name → @username → "(no name)", with the phone masked and
  last; without the username in this payload, anyone who never set a display name falls straight
  through to their phone number on every list.
  """
  use AuthService.DataCase, async: false

  alias AuthService.Accounts

  @tenant "00000000-0000-0000-0000-000000000001"

  defp user!(display_name, username) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active')",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}"]
    )

    Repo.query!(
      "INSERT INTO user_profiles (user_id, app_id, display_name, username, username_key) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, $4, lower($4))",
      [id, @tenant, display_name, username]
    )

    id
  end

  @tag :postgres_integration
  test "a summary carries display name, username and phone together" do
    id = user!("Guru Singh", "guru")

    %{summaries: [summary]} = Accounts.list_user_summaries(%{"user_ids" => [id]})

    assert summary.display_name == "Guru Singh"
    assert summary.username == "guru"
    assert is_binary(summary.phone_number)
  end

  @tag :postgres_integration
  test "a user with no display name still has a handle to be shown by" do
    id = user!(nil, "nameless")

    %{summaries: [summary]} = Accounts.list_user_summaries(%{"user_ids" => [id]})

    assert is_nil(summary.display_name)
    assert summary.username == "nameless"
  end
end
