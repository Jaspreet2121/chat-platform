defmodule AuthService.Schemas.LoginAttempt do
  @moduledoc """
  Ecto schema for the `login_attempts` table.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "login_attempts" do
    field(:login_identifier, :string)
    field(:user_id, :binary_id)
    field(:success, :boolean)
    field(:failure_reason, :string)
    field(:ip_address, :string)
    field(:user_agent, :string)
    field(:created_at, :utc_datetime_usec)
  end

  def changeset(login_attempt, attrs) do
    login_attempt
    |> cast(attrs, [
      :login_identifier,
      :user_id,
      :success,
      :failure_reason,
      :ip_address,
      :user_agent
    ])
    |> validate_required([:login_identifier, :success])
    |> foreign_key_constraint(:user_id)
  end
end
