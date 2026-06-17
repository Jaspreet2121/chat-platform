defmodule AuthService.Accounts do
  @moduledoc """
  Data-access boundary for auth identities in `users_auth`.
  """

  alias AuthService.Repo
  alias AuthService.Schemas.UserAuth

  def user_changeset(attrs \\ %{}) do
    UserAuth.changeset(%UserAuth{}, attrs)
  end

  def create_user(attrs) do
    attrs
    |> user_changeset()
    |> Repo.insert()
  end

  def get_user(id), do: Repo.get(UserAuth, id)

  def get_by_phone_number(phone_number) do
    Repo.get_by(UserAuth, phone_number: phone_number)
  end

  def get_by_email(email) do
    Repo.get_by(UserAuth, email: email)
  end
end
