defmodule UserService.Schemas.UserProfile do
  @moduledoc """
  Ecto schema for the `user_profiles` table.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:user_id, :binary_id, autogenerate: false}

  schema "user_profiles" do
    field(:display_name, :string)
    field(:avatar_media_id, :binary_id)
    field(:avatar_object_key, :string)
    field(:bio, :string)

    # The optional @handle (080): `username` as typed (display), `username_key` = lowercase (uniqueness +
    # lookup, per-tenant). DELIBERATELY not cast by the changesets below — every write goes through
    # UserService.Usernames (validation, holds, change budget); a generic profile update can't touch them.
    field(:username, :string)
    field(:username_key, :string)

    # Payment + business card (100). upi_id/payment_name come from a scanned upi:// payload (or
    # manual entry); upi_merchant is the OWNER-ONLY jsonb passthrough of the scanned params;
    # upi_qr_media_id points at the server-generated QR PNG (a normal user-owned media asset).
    field(:upi_id, :string)
    field(:payment_name, :string)
    field(:upi_merchant, :map)
    field(:upi_qr_media_id, :binary_id)
    field(:address, :string)
    field(:website, :string)
    field(:business_email, :string)
    field(:business_hours, :string)

    # {"payment": everyone|contacts|nobody (default contacts), "business": everyone|nobody (default
    # everyone)} — enforced by the gateway presenter, defaults applied at read.
    field(:profile_visibility, :map)

    # The profile's tenant (migration 048). Read-only here — surfaced so the gateway can presign the
    # avatar scoped to the ASSET's app (the /avatar route is unauthenticated → no caller app_id).
    field(:app_id, :binary_id)
    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(user_profile, attrs) do
    user_profile
    |> cast(attrs, [
      :user_id,
      :display_name,
      :avatar_media_id,
      :avatar_object_key,
      :bio,
      :upi_id,
      :payment_name,
      :upi_merchant,
      :upi_qr_media_id,
      :address,
      :website,
      :business_email,
      :business_hours,
      :profile_visibility
    ])
    |> validate_required([:user_id, :display_name])
    |> validate_payment_business()
    |> foreign_key_constraint(:user_id)
  end

  def update_changeset(user_profile, attrs) do
    user_profile
    |> cast(attrs, [
      :display_name,
      :avatar_media_id,
      :avatar_object_key,
      :bio,
      :upi_id,
      :payment_name,
      :upi_merchant,
      :upi_qr_media_id,
      :address,
      :website,
      :business_email,
      :business_hours,
      :profile_visibility
    ])
    |> validate_required([:display_name])
    |> validate_payment_business()
  end

  # The 100 contract's field bounds. website must be https (a payment-adjacent link must never
  # downgrade); business_email is a shape check only (never verified — display data, not identity).
  defp validate_payment_business(changeset) do
    changeset
    |> validate_length(:payment_name, max: 100)
    |> validate_length(:address, max: 300)
    |> validate_length(:website, max: 300)
    |> validate_length(:business_email, max: 200)
    |> validate_length(:business_hours, max: 200)
    |> validate_format(:website, ~r/^https:\/\//, message: "must be an https:// URL")
    |> validate_format(:business_email, ~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/,
      message: "must look like an email address"
    )
  end
end
