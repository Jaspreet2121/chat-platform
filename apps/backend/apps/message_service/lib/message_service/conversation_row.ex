defmodule MessageService.ConversationRow do
  @moduledoc """
  The three columns of the conversation row that message-service reads straight from the shared
  Postgres: `secret` (sealed-vs-plaintext policy on the create path), `created_at` (the
  timeline's age bound on the read path) and `app_id` (tenant scope of the media-link presign,
  `MessageService.MediaLinks`). ONE query serves all — the read that used to fetch
  `secret` alone now carries `created_at` beside it, so the timeline floor costs no extra query on
  the path that already had one, and exactly one point read on the path that did not.

  No runtime dependency on the conversation service, same as every other cross-row read here.
  """

  @doc "{:ok, %{secret, created_at, app_id}} | :not_found | {:error, reason} — never raises."
  def fetch(conversation_id) when is_binary(conversation_id) and conversation_id != "" do
    # app_id rides along for the media-link presign (tenant scope of the media_assets lookup);
    # cast to text here so the caller never sees a raw 16-byte uuid.
    case MessageService.Repo.query(
           "SELECT secret, created_at, app_id::text FROM conversations WHERE id = $1::text::uuid",
           [conversation_id]
         ) do
      {:ok, %{rows: [[secret, created_at, app_id]]}} ->
        {:ok, %{secret: secret == true, created_at: created_at, app_id: app_id}}

      {:ok, _} ->
        :not_found

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  def fetch(_conversation_id), do: :not_found

  @doc """
  The earliest day a message of this conversation can be bucketed in: the day BEFORE it was
  created, the one day being clock-skew slack between Postgres `created_at` and the Scylla bucket
  key a message minted a moment later may carry. nil when the row is unknown or unreadable — the
  caller falls back to its hard cap rather than failing the page.
  """
  def timeline_floor(conversation_id) do
    case fetch(conversation_id) do
      {:ok, %{created_at: %DateTime{} = dt}} -> Date.add(DateTime.to_date(dt), -1)
      {:ok, %{created_at: %NaiveDateTime{} = ndt}} -> Date.add(NaiveDateTime.to_date(ndt), -1)
      _ -> nil
    end
  end
end
