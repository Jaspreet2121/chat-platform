defmodule MessageService.Schemas.PollVote do
  @moduledoc """
  Ecto schema for the Postgres-backed `poll_votes` table (079) — one row per (message, user, option).
  Aggregates are always computed from these rows at fetch time; the definition lives in the poll
  message's metadata.
  """

  use Ecto.Schema

  @primary_key false

  schema "poll_votes" do
    field(:conversation_id, :binary_id)
    field(:message_id, :binary_id)
    field(:user_id, :binary_id)
    field(:option_id, :string)
    field(:created_at, :utc_datetime_usec)
  end
end
