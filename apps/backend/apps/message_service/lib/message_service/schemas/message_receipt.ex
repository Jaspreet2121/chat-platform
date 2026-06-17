defmodule MessageService.Schemas.MessageReceipt do
  @moduledoc """
  Ecto schema for the Postgres-backed `message_receipts` table.

  Mirrors the Scylla receipt shape but with explicit `delivered_at`/`read_at`
  columns, so a delivered receipt is preserved when a later read receipt arrives.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "message_receipts" do
    field(:conversation_id, :binary_id, primary_key: true)
    field(:message_id, :binary_id, primary_key: true)
    field(:user_id, :binary_id, primary_key: true)
    field(:status, :string)
    field(:delivered_at, :utc_datetime_usec)
    field(:read_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [
      :conversation_id,
      :message_id,
      :user_id,
      :status,
      :delivered_at,
      :read_at,
      :updated_at
    ])
    |> validate_required([:conversation_id, :message_id, :user_id, :status])
  end
end
