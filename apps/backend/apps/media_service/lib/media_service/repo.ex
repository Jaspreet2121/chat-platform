defmodule MediaService.Repo do
  @moduledoc """
  media_service's Repo — the shared Postgres, same as the other services' repos. Added so the write path
  (create_upload/complete_upload) can persist `media_assets` rows (tenant + ownership), which the read path
  (Phase 2) will authorize against. Prod reaches Postgres via the shared `DATABASE_URL`.
  """
  use Ecto.Repo,
    otp_app: :media_service,
    adapter: Ecto.Adapters.Postgres
end
