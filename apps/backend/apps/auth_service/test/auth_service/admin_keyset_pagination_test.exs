defmodule AuthService.AdminKeysetPaginationTest do
  @moduledoc """
  The admin lists page by KEYSET, and this is the test that says why it had to change.

  Under `LIMIT n OFFSET n`, a row inserted between page 1 and page 2 shifts every later row down by
  one, so the reader is never shown the row that slid across the boundary. On these lists that is not
  a hypothetical: users sign up, reports arrive, and the audit log gets a row every time an admin
  opens a user. A moderator paging a report queue and missing a report is exactly the failure this
  prevents, so the test SIMULATES the insert mid-read rather than asserting on a page shape.

  It also pins the other half: filters survive paging. A status filter that silently resets on page 2
  is worse than no filter, because the reader believes they are still looking at open reports.
  """
  use AuthService.DataCase, async: false

  alias AuthService.Accounts
  alias AuthService.Moderation

  @tenant "00000000-0000-0000-0000-000000000001"

  # Explicit, SPREAD timestamps. Rows inserted in one transaction all share now() in the sandbox
  # (it is frozen for the transaction), which would make every row a tie on the sort column and test
  # nothing about ordering.
  defp seed_user!(minutes_ago, opts \\ []) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, $4, now() - ($5 || ' minutes')::interval, now())",
      [
        id,
        @tenant,
        "+1555#{System.unique_integer([:positive])}",
        Keyword.get(opts, :status, "active"),
        to_string(minutes_ago)
      ]
    )

    id
  end

  defp seed_report!(reporter, reported, minutes_ago, status) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO user_reports (id, reporter_user_id, reported_user_id, reason, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, 'spam', $4, " <>
        "now() - ($5 || ' minutes')::interval, now())",
      [id, reporter, reported, status, to_string(minutes_ago)]
    )

    id
  end

  @tag :postgres_integration
  test "a user who signs up mid-read is not allowed to hide the next user" do
    # Ten users, newest first: 1 minute old through 10 minutes old.
    ids = for m <- 1..10, do: {m, seed_user!(m)}

    first = Accounts.list_users(%{"app_id" => @tenant, "limit" => 5})
    assert length(first.users) == 5
    assert first.next_cursor

    # THE INSERT THAT BREAKS OFFSET. A brand-new sign-up lands at the TOP of the list, between the
    # two reads. Under OFFSET 5 the boundary row would be pushed to position 6 and served twice while
    # the row at position 11 was never served at all.
    _newcomer = seed_user!(0)

    second =
      Accounts.list_users(%{"app_id" => @tenant, "limit" => 5, "cursor" => first.next_cursor})

    seen = Enum.map(first.users ++ second.users, & &1.user_id)

    # Nothing repeated...
    assert length(Enum.uniq(seen)) == length(seen)
    # ...and every one of the original ten seeded rows is on one of the two pages.
    for {_m, id} <- ids, do: assert(id in seen)
  end

  @tag :postgres_integration
  test "paging forward then back returns to exactly the first page" do
    for m <- 1..9, do: seed_user!(m)

    first = Accounts.list_users(%{"app_id" => @tenant, "limit" => 4})
    # Nothing behind the first page, so no Back button.
    assert first.prev_cursor == nil

    second =
      Accounts.list_users(%{"app_id" => @tenant, "limit" => 4, "cursor" => first.next_cursor})

    assert second.prev_cursor

    back =
      Accounts.list_users(%{
        "app_id" => @tenant,
        "limit" => 4,
        "cursor" => second.prev_cursor,
        "direction" => "prev"
      })

    # Same rows, same order. A backward page that came back reversed, or one row off, is the classic
    # keyset bug and it is invisible until somebody trusts the list.
    assert Enum.map(back.users, & &1.user_id) == Enum.map(first.users, & &1.user_id)
  end

  @tag :postgres_integration
  test "the page size is the server's — a caller cannot widen it" do
    for m <- 1..60, do: seed_user!(m)

    huge = Accounts.list_users(%{"app_id" => @tenant, "limit" => 5_000})

    assert huge.page_size == SharedInfra.AdminCursor.page_size()
    assert length(huge.users) <= SharedInfra.AdminCursor.page_size()
  end

  @tag :postgres_integration
  test "a status filter survives paging, and never leaks a row it excludes" do
    reporter = seed_user!(100)
    subject = seed_user!(99)

    for m <- 1..6, do: seed_report!(reporter, subject, m, "open")
    for m <- 7..9, do: seed_report!(reporter, subject, m, "resolved")

    filter = %{"app_id" => @tenant, "status" => "open", "limit" => 4}
    {:ok, first} = Moderation.list_reports(filter)

    assert length(first.reports) == 4
    assert Enum.all?(first.reports, &(&1.status == "open"))

    {:ok, second} = Moderation.list_reports(Map.put(filter, "cursor", first.next_cursor))

    # The filter is re-sent with the cursor, so page 2 is still open reports only — and the two
    # resolved rows sitting further down the table never appear.
    assert Enum.all?(second.reports, &(&1.status == "open"))
    assert length(first.reports ++ second.reports) == 6
  end

  @tag :postgres_integration
  test "a malformed cursor lands on the first page rather than failing" do
    for m <- 1..5, do: seed_user!(m)

    clean = Accounts.list_users(%{"app_id" => @tenant, "limit" => 3})
    junk = Accounts.list_users(%{"app_id" => @tenant, "limit" => 3, "cursor" => "not-a-cursor"})

    assert Enum.map(junk.users, & &1.user_id) == Enum.map(clean.users, & &1.user_id)
  end

  @tag :postgres_integration
  test "the audit list pages by keyset and carries where the action came from" do
    actor = seed_user!(50)

    for m <- 1..7 do
      Repo.query!(
        "INSERT INTO audit_logs (actor_user_id, action, target_type, target_id, metadata, " <>
          "ip_address, user_agent, created_at) " <>
          "VALUES ($1::text::uuid, 'user.view', 'user', $2, '{}'::jsonb, '203.0.113.7', 'curl/8', " <>
          "now() - ($3 || ' minutes')::interval)",
        [actor, "target-#{m}", to_string(m)]
      )
    end

    {:ok, first} = Moderation.list_audit(%{"limit" => 4})
    assert length(first.entries) == 4

    # An audit row recording WHO and WHAT but not FROM WHERE cannot answer the question it exists for.
    assert Enum.all?(first.entries, &(&1.ip_address == "203.0.113.7"))
    assert Enum.all?(first.entries, &(&1.user_agent == "curl/8"))

    {:ok, second} = Moderation.list_audit(%{"limit" => 4, "cursor" => first.next_cursor})

    ids = Enum.map(first.entries ++ second.entries, & &1.id)
    assert length(Enum.uniq(ids)) == length(ids)
  end
end
