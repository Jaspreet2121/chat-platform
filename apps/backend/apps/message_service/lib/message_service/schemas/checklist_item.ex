defmodule MessageService.Schemas.ChecklistItem do
  @moduledoc """
  Ecto schema for the Postgres-backed `checklist_items` table (126) — the MUTABLE state of a
  checklist message's items: a tick on a definition item (text/position NULL), or an ADDED item
  (text + position set). The definition itself lives in the message's `metadata.checklist`, and the
  aggregate is always computed from both at fetch time. Mirrors `Schemas.PollVote`.
  """

  use Ecto.Schema

  @primary_key false

  schema "checklist_items" do
    field(:message_id, :binary_id)
    field(:item_id, :string)
    field(:conversation_id, :binary_id)
    field(:text, :string)
    field(:position, :integer)
    field(:done, :boolean)
    field(:done_by, :binary_id)
    field(:done_at, :utc_datetime_usec)
    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end
end
