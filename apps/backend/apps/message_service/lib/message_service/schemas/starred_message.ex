defmodule MessageService.Schemas.StarredMessage do
  @moduledoc """
  Ecto schema for the Postgres-backed `starred_messages` table.

  Per-user private bookmark: ONE star per (user, message) — PK `(user_id, message_id)`. Starring is
  idempotent (an upsert that does nothing on conflict); `created_at` orders the Starred view.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "starred_messages" do
    field(:user_id, :binary_id, primary_key: true)
    field(:message_id, :binary_id, primary_key: true)
    field(:conversation_id, :binary_id)
    field(:created_at, :utc_datetime_usec)
  end

  def changeset(star, attrs) do
    star
    |> cast(attrs, [:user_id, :message_id, :conversation_id, :created_at])
    |> validate_required([:user_id, :message_id, :conversation_id])
  end
end
