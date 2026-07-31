defmodule UserService.Schemas.UserPrivacySettings do
  @moduledoc """
  Ecto schema for the `user_privacy_settings` table.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @visibility_values ["everyone", "contacts", "nobody"]

  @primary_key {:user_id, :binary_id, autogenerate: false}

  schema "user_privacy_settings" do
    field(:last_seen_visibility, :string, default: "contacts")
    field(:profile_photo_visibility, :string, default: "contacts")
    field(:read_receipts_enabled, :boolean, default: true)
    # "Who can find me by phone number" (084) — a BOOLEAN, deliberately not the visibility vocabulary
    # (phone discovery is performed by non-contacts, so a "contacts" tier would be a no-op).
    field(:discoverable_by_phone, :boolean, default: true)
    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(user_privacy_settings, attrs) do
    user_privacy_settings
    |> cast(attrs, [
      :user_id,
      :last_seen_visibility,
      :profile_photo_visibility,
      :read_receipts_enabled,
      :discoverable_by_phone
    ])
    |> validate_required([
      :user_id,
      :last_seen_visibility,
      :profile_photo_visibility,
      :read_receipts_enabled,
      :discoverable_by_phone
    ])
    |> validate_visibility()
    |> foreign_key_constraint(:user_id)
  end

  def update_changeset(user_privacy_settings, attrs) do
    user_privacy_settings
    |> cast(attrs, [
      :last_seen_visibility,
      :profile_photo_visibility,
      :read_receipts_enabled,
      :discoverable_by_phone
    ])
    |> validate_required([
      :last_seen_visibility,
      :profile_photo_visibility,
      :read_receipts_enabled,
      :discoverable_by_phone
    ])
    |> validate_visibility()
  end

  defp validate_visibility(changeset) do
    changeset
    |> validate_inclusion(:last_seen_visibility, @visibility_values)
    |> validate_inclusion(:profile_photo_visibility, @visibility_values)
  end
end
