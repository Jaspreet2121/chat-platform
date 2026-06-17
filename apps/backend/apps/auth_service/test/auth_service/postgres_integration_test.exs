defmodule AuthService.PostgresIntegrationTest do
  use AuthService.DataCase, async: false

  alias AuthService.Schemas.UserAuth

  @tag :postgres_integration
  test "inserts and selects a users_auth row through the auth repo" do
    user_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    {1, _rows} =
      Repo.insert_all(UserAuth, [
        %{
          id: user_id,
          phone_number: unique_phone_number(),
          status: "active",
          created_at: now,
          updated_at: now
        }
      ])

    assert %UserAuth{id: ^user_id, status: "active"} = Repo.get(UserAuth, user_id)
  end

  defp unique_phone_number do
    "+1555#{System.unique_integer([:positive])}"
  end
end
