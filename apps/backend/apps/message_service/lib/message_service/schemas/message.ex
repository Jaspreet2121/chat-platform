defmodule MessageService.Schemas.Message do
  @moduledoc """
  Ecto schema for the Postgres-backed `messages` table.

  This is the durability backend used behind `MESSAGE_STORE_ADAPTER=postgres`.
  ScyllaDB remains the documented long-term high-write backend (deferred). The
  table intentionally carries NO cross-service foreign keys (message_id /
  conversation_id / sender_user_id are plain UUIDs) so this store stays a single
  self-contained Repo.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:message_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "messages" do
    field(:conversation_id, :binary_id)
    field(:sender_user_id, :binary_id)
    field(:message_type, :string)
    field(:body, :string)
    field(:media_id, :binary_id)
    field(:reply_to_message_id, :binary_id)
    field(:status, :string, default: "active")
    field(:metadata, :map, default: %{})
    field(:created_at, :utc_datetime_usec)
    field(:edited_at, :utc_datetime_usec)
    field(:deleted_at, :utc_datetime_usec)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :message_id,
      :conversation_id,
      :sender_user_id,
      :message_type,
      :body,
      :media_id,
      :reply_to_message_id,
      :status,
      :metadata,
      :created_at,
      :edited_at,
      :deleted_at
    ])
    |> validate_required([
      :message_id,
      :conversation_id,
      :sender_user_id,
      :message_type,
      :status
    ])
  end
end
