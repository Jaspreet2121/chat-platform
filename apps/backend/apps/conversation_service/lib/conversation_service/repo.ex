defmodule ConversationService.Repo do
  use Ecto.Repo,
    otp_app: :conversation_service,
    adapter: Ecto.Adapters.Postgres
end
