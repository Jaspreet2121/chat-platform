defmodule AuthService.LoginAttempts do
  @moduledoc """
  Data-access boundary for login attempt audit records.
  """

  alias AuthService.Repo
  alias AuthService.Schemas.LoginAttempt

  def login_attempt_changeset(attrs \\ %{}) do
    LoginAttempt.changeset(%LoginAttempt{}, attrs)
  end

  def record_login_attempt(attrs) do
    attrs
    |> login_attempt_changeset()
    |> Repo.insert()
  end
end
