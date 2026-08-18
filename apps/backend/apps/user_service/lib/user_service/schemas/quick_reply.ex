defmodule UserService.Schemas.QuickReply do
  @moduledoc """
  Ecto schema for `quick_replies` (100) — one per-user custom slash command. Uniqueness of
  (user_id, shortcut) is the partial-free unique index `quick_replies_user_shortcut`; format/length
  rules live in `UserService.QuickReplies` (single write path).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "quick_replies" do
    field(:app_id, :binary_id)
    field(:user_id, :binary_id)
    field(:shortcut, :string)
    field(:body, :string)
    field(:media_id, :binary_id)
    field(:position, :integer, default: 0)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(quick_reply, attrs) do
    quick_reply
    |> cast(attrs, [:app_id, :user_id, :shortcut, :body, :media_id, :position])
    |> validate_required([:app_id, :user_id, :shortcut, :body])
    |> unique_constraint(:shortcut, name: :quick_replies_user_shortcut)
    |> foreign_key_constraint(:user_id)
  end
end
