defmodule MessageService.ConversationRow do
  @moduledoc """
  The conversation facts message-service reads straight from the shared Postgres: `secret`
  (sealed-vs-plaintext policy on the create path), `created_at` (the timeline's age bound on the read
  path), `app_id` (tenant scope of the media-link presign, `MessageService.MediaLinks`), and — since
  128 — `direct_key` plus whether this conversation is an UNACCEPTED MESSAGE REQUEST.

  ONE query serves all, and that is the whole point of this module. The read that once fetched
  `secret` alone gained `created_at`, then `app_id`, and now the request facts, so each new caller
  costs no extra query on the path that already had one. The create path calls this exactly once per
  message for the secret policy; the stranger budget rides that same row, which is why an ACCEPTED
  conversation pays nothing at all for this feature — not one additional statement per send.

  `request_pending` is a correlated EXISTS over `conversation_participants` rather than a join, so a
  conversation with no pending row short-circuits on the index and the common case stays a point read.

  `exclude_user_id` is what makes `request_pending` mean the useful thing on the send path: "somebody
  OTHER than this sender has not accepted". Pass the sender and a RECIPIENT who replies before
  accepting reads as not-pending, so their own reply is never charged against the stranger's budget.
  Omit it and the flag means "anyone at all is pending", which is what a non-send caller wants.

  No runtime dependency on the conversation service, same as every other cross-row read here.
  """

  @doc """
  `{:ok, %{secret, created_at, app_id, direct_key, request_pending}}` | `:not_found` |
  `{:error, reason}` — never raises.
  """
  def fetch(conversation_id, exclude_user_id \\ nil)

  def fetch(conversation_id, exclude_user_id)
      when is_binary(conversation_id) and conversation_id != "" do
    # app_id rides along for the media-link presign (tenant scope of the media_assets lookup);
    # cast to text here so the caller never sees a raw 16-byte uuid.
    case MessageService.Repo.query(
           "SELECT c.secret, c.created_at, c.app_id::text, c.direct_key, " <>
             "EXISTS (SELECT 1 FROM conversation_participants p " <>
             "        WHERE p.conversation_id = c.id AND p.request_pending_at IS NOT NULL " <>
             "          AND ($2::text IS NULL OR p.user_id <> $2::text::uuid)) " <>
             "FROM conversations c WHERE c.id = $1::text::uuid",
           [conversation_id, exclude_user_id]
         ) do
      {:ok, %{rows: [[secret, created_at, app_id, direct_key, request_pending]]}} ->
        {:ok,
         %{
           secret: secret == true,
           created_at: created_at,
           app_id: app_id,
           direct_key: direct_key,
           request_pending: request_pending == true
         }}

      {:ok, _} ->
        :not_found

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  def fetch(_conversation_id, _exclude_user_id), do: :not_found

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
