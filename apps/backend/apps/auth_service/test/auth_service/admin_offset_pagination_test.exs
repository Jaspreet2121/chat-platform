defmodule AuthService.AdminOffsetPaginationTest do
  @moduledoc """
  Numbered pages over real rows: the right rows on the right page, a total that matches the filter,
  and a page size the caller cannot widen.

  The trap with offset paging is not the arithmetic — it is the total being counted over a
  different WHERE than the rows, so "Page 1 of 12" is about a list the operator is not looking at.
  So the reports test filters by status and requires the total to agree with the rows.
  """
  use AuthService.DataCase, async: false

  alias AuthService.Accounts
  alias AuthService.Moderation

  @tenant "00000000-0000-0000-0000-000000000001"

  # Explicit, SPREAD timestamps: rows inserted in one transaction share now() in the sandbox, which
  # would make every row a tie on the sort column and test nothing about the order.
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
    Repo.query!(
      "INSERT INTO user_reports (reporter_user_id, reported_user_id, reason, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'spam', $3, now() - ($4 || ' minutes')::interval, now())",
      [reporter, reported, status, to_string(minutes_ago)]
    )
  end

  @tag :postgres_integration
  test "page 2 of 3 holds exactly the rows between the newest page and the last" do
    # 1..7 minutes old: newest first, so page 1 = [1,2,3], page 2 = [4,5,6], page 3 = [7].
    ids = for m <- 1..7, into: %{}, do: {m, seed_user!(m)}

    page2 = Accounts.list_users(%{"app_id" => @tenant, "page" => 2, "page_size" => 3})

    assert page2.page == 2
    assert page2.page_size == 3
    assert page2.total == 7
    assert page2.total_pages == 3
    assert Enum.map(page2.users, & &1.user_id) == [ids[4], ids[5], ids[6]]

    page3 = Accounts.list_users(%{"app_id" => @tenant, "page" => 3, "page_size" => 3})
    assert Enum.map(page3.users, & &1.user_id) == [ids[7]]
  end

  @tag :postgres_integration
  test "a page past the end is empty but the envelope still says how many pages there are" do
    for m <- 1..4, do: seed_user!(m)

    beyond = Accounts.list_users(%{"app_id" => @tenant, "page" => 9, "page_size" => 3})
    assert beyond.users == []
    assert beyond.total == 4
    assert beyond.total_pages == 2
  end

  @tag :postgres_integration
  test "the page size is the server's — a caller cannot widen it" do
    for m <- 1..110, do: seed_user!(m)

    huge = Accounts.list_users(%{"app_id" => @tenant, "page_size" => 5_000})
    assert huge.page_size == 100
    assert length(huge.users) == 100
    assert huge.total_pages == 2
  end

  @tag :postgres_integration
  test "the total is counted over the SAME filter as the rows" do
    reporter = seed_user!(100)
    subject = seed_user!(99)

    for m <- 1..5, do: seed_report!(reporter, subject, m, "open")
    for m <- 6..8, do: seed_report!(reporter, subject, m, "resolved")

    {:ok, open} =
      Moderation.list_reports(%{"app_id" => @tenant, "status" => "open", "page_size" => 2})

    # Two on this page, five in total, three pages — all about OPEN reports, not all reports.
    assert length(open.reports) == 2
    assert Enum.all?(open.reports, &(&1.status == "open"))
    assert open.total == 5
    assert open.total_pages == 3

    {:ok, all} = Moderation.list_reports(%{"app_id" => @tenant, "page_size" => 2})
    assert all.total == 8
  end
end
