defmodule AuthService.ModerationLiveSourceTest do
  @moduledoc """
  Drop-blockers #4: the moderation user profile's `messages_sent` and `last_active_at` now read
  `message_search` (the live store's copy) — the frozen Postgres `messages` table had stuck both
  since the cutover. Frozen-vs-live discrimination, same shape as the other re-point suites.
  """
  use AuthService.DataCase, async: false

  alias AuthService.Moderation

  @tenant "00000000-0000-0000-0000-000000000001"

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active')",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp conversation!(creator) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid)",
      [id, @tenant, creator]
    )

    id
  end

  @tag :postgres_integration
  test "messages_sent and last_active_at come from the live copy, not the frozen table" do
    user = user!()
    conversation = conversation!(user)

    # Frozen: 3 rows, one very recent — if last_active still read the frozen table, ITS timestamp
    # would win the GREATEST below.
    for _ <- 1..3 do
      Repo.query!(
        "INSERT INTO messages (message_id, conversation_id, app_id, sender_user_id, message_type, " <>
          "body, created_at) VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, " <>
          "$4::text::uuid, 'text', 'frozen', now() - interval '1 minute')",
        [Ecto.UUID.generate(), conversation, @tenant, user]
      )
    end

    # Live: 1 indexed row, older than the frozen ones.
    Repo.query!(
      "INSERT INTO message_search (message_id, conversation_id, sender_user_id, created_at, " <>
        "search_text) VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, " <>
        "now() - interval '2 days', 'live')",
      [Ecto.UUID.generate(), conversation, user]
    )

    {:ok, detail} = Moderation.user_detail(%{"user_id" => user})

    assert detail.stats.messages_sent == 1

    # last_active derives from the LIVE copy's max(created_at) (2 days ago), not the frozen rows
    # from a minute ago — parsed and compared, not string-matched.
    {:ok, last_active, _} = DateTime.from_iso8601(detail.stats.last_active_at)
    assert DateTime.diff(DateTime.utc_now(), last_active, :hour) >= 47
  end
end
