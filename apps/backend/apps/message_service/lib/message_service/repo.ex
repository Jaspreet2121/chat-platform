defmodule MessageService.Repo do
  use Ecto.Repo,
    otp_app: :message_service,
    adapter: Ecto.Adapters.Postgres
end
