defmodule MessageService.AnalyticsLiveSourceTest do
  @moduledoc """
  Drop-blockers #3 (DECISION_LOG [2026-08-09]): admin analytics now count `message_search` — the
  live store's copy — not the frozen Postgres `messages` table, where every windowed number had
  read ZERO since the cutover and every total was stuck.

  The load-bearing shape, same as the admin-conversation slice: seed rows in BOTH tables and
  require the counts to see only the live ones. A frozen row leaking back in means the re-point
  silently regressed.
  """
  use MessageService.DataCase, async: false

  alias MessageService.Analytics

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

  defp frozen_message!(conversation, sender) do
    Repo.query!(
      "INSERT INTO messages (message_id, conversation_id, app_id, sender_user_id, message_type, " <>
        "body, created_at) VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, " <>
        "$4::text::uuid, 'text', 'frozen', now() - interval '1 hour')",
      [Ecto.UUID.generate(), conversation, @tenant, sender]
    )
  end

  defp indexed_message!(conversation, sender, opts \\ []) do
    at = Keyword.get(opts, :at, DateTime.utc_now())

    Repo.query!(
      "INSERT INTO message_search (message_id, conversation_id, sender_user_id, created_at, " <>
        "search_text) VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, $4, 'live')",
      [Ecto.UUID.generate(), conversation, sender, at]
    )
  end

  @tag :postgres_integration
  test "overview: totals and windowed activity count the LIVE copy, never the frozen table" do
    sender = user!()
    conversation = conversation!(sender)

    # Frozen rows are RECENT on the clock (1h ago) — so if any windowed count still read the frozen
    # table, these would leak into messages_24h and the test would see 5, not 2.
    for _ <- 1..3, do: frozen_message!(conversation, sender)
    for _ <- 1..2, do: indexed_message!(conversation, sender)

    %{totals: totals, activity: activity} = Analytics.overview(@tenant)

    assert totals.messages == 2
    assert activity.messages_24h == 2
    assert activity.messages_7d == 2
    assert activity.active_conversations_7d == 1
  end

  @tag :postgres_integration
  test "timeseries: the daily message series comes from the live copy" do
    sender = user!()
    conversation = conversation!(sender)
    frozen_message!(conversation, sender)
    indexed_message!(conversation, sender)
    indexed_message!(conversation, sender)

    %{messages: series} = Analytics.timeseries(2, @tenant)
    today = Enum.at(series, -1)

    assert today.count == 2
  end
end
