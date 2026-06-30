defmodule SharedInfra.Tenancy do
  @moduledoc """
  Multi-tenant helpers. Every core row belongs to an "app" (tenant). The existing single-tenant
  product runs as the fixed DEFAULT app ("tenant zero"); auth assigns it implicitly and core writes
  fall back to it, so the current app keeps working unchanged while the data model is now per-app.

  Mirrors the seeded row in migration 048 (`apps` table) — keep this UUID in sync with that migration.
  """

  @default_app_id "00000000-0000-0000-0000-000000000001"

  @doc "The default app id (tenant zero) — what the existing product resolves to."
  def default_app_id, do: @default_app_id

  @doc "Resolve an app id from a value, falling back to the default app when absent/blank."
  def app_id_or_default(app_id) when is_binary(app_id) and app_id != "", do: app_id
  def app_id_or_default(_), do: @default_app_id
end
