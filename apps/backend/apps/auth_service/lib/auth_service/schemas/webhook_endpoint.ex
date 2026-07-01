defmodule AuthService.Schemas.WebhookEndpoint do
  @moduledoc """
  Ecto schema for `webhook_endpoints` — a registered integrator URL per app. `signing_secret` is
  RECOVERABLE (the worker HMAC-signs each delivery with it; the integrator verifies with the same
  secret) — stored plaintext (no app-level encryption key) and returned ONCE at creation.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "webhook_endpoints" do
    field(:app_id, :binary_id)
    field(:url, :string)
    field(:signing_secret, :string)
    field(:enabled, :boolean, default: true)
    field(:event_types, {:array, :string}, default: [])
    field(:created_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end

  def changeset(endpoint, attrs) do
    endpoint
    |> cast(attrs, [
      :app_id,
      :url,
      :signing_secret,
      :enabled,
      :event_types,
      :created_at,
      :updated_at
    ])
    |> validate_required([:app_id, :url, :signing_secret])
    |> validate_format(:url, ~r{^https?://}, message: "must be an http(s) URL")
    |> foreign_key_constraint(:app_id)
  end
end
