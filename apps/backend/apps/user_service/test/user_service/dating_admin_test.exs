defmodule UserService.DatingAdminTest do
  @moduledoc """
  The admin Matches read (`users.sensitive.view`). The properties that matter for a surface over
  personal data: the page size is the SERVER's, not the caller's; paging is stable under inserts;
  and the read is scoped to one tenant.
  """
  use UserService.DataCase, async: false

  alias UserService.DatingAdmin

  @app_id "00000000-0000-0000-0000-000000000001"

  defp user!(display_name) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, password_hash, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', 'active', now(), now())",
      [id, @app_id, "+1#{System.unique_integer([:positive])}"]
    )

    Repo.query!(
      "INSERT INTO user_profiles (user_id, display_name, app_id, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2, $3::text::uuid, now(), now())",
      [id, display_name, @app_id]
    )

    id
  end

  defp match!(low, high, minutes_ago) do
    [a, b] = Enum.sort([low, high])

    Repo.query!(
      "INSERT INTO dating_matches (app_id, user_low_id, user_high_id, matched_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, now() - ($4 || ' minutes')::interval)",
      [@app_id, a, b, Integer.to_string(minutes_ago)]
    )
  end

  @tag :postgres_integration
  test "the PAGE SIZE IS THE SERVER'S — a caller may pick a size, never one past the ceiling" do
    anchor = user!("Anchor")
    for i <- 1..110, do: match!(anchor, user!("Peer #{i}"), i)

    # Ask for far more than the cap.
    assert {:ok, %{matches: matches, page_size: 100, total: 110, total_pages: 2}} =
             DatingAdmin.list_matches(%{"app_id" => @app_id, "page_size" => "10000"})

    assert length(matches) == 100

    # Junk, zero and negative all land on the server's default rather than disabling the bound.
    for bad <- ["0", "-1", "abc", nil] do
      assert {:ok, %{matches: rows, page_size: size}} =
               DatingAdmin.list_matches(%{"app_id" => @app_id, "page_size" => bad})

      assert size == SharedInfra.AdminPage.default_size()
      assert length(rows) == size
    end

    # Narrowing IS allowed.
    assert {:ok, %{matches: five}} =
             DatingAdmin.list_matches(%{"app_id" => @app_id, "page_size" => "5"})

    assert length(five) == 5
  end

  @tag :postgres_integration
  test "numbered pages walk the whole list once — no skips, no repeats, newest first" do
    anchor = user!("Anchor")
    for i <- 1..12, do: match!(anchor, user!("Peer #{i}"), i)

    pages =
      for page <- 1..3 do
        {:ok, result} =
          DatingAdmin.list_matches(%{"app_id" => @app_id, "page" => page, "page_size" => "5"})

        assert result.total == 12
        assert result.total_pages == 3
        result.matches
      end

    ids = pages |> List.flatten() |> Enum.map(& &1.id)
    assert length(ids) == 12
    assert length(Enum.uniq(ids)) == 12

    # Newest first across the whole walk, not just within a page.
    stamps = pages |> List.flatten() |> Enum.map(& &1.matched_at)
    assert stamps == Enum.sort(stamps, :desc)
    assert length(List.last(pages)) == 2
  end

  @tag :postgres_integration
  test "a per-user view returns that user's matches, both sides of the pair, and nothing else" do
    alice = user!("Alice")
    bob = user!("Bob")
    carol = user!("Carol")
    stranger_a = user!("Stranger A")
    stranger_b = user!("Stranger B")

    match!(alice, bob, 1)
    match!(carol, alice, 2)
    match!(stranger_a, stranger_b, 3)

    assert {:ok, %{matches: rows}} =
             DatingAdmin.user_matches(%{"app_id" => @app_id, "user_id" => alice})

    assert length(rows) == 2

    assert Enum.all?(rows, fn r -> alice in [r.user_low_id, r.user_high_id] end)
    # Names come back so the console never has to resolve ids itself.
    assert Enum.any?(rows, &(&1.user_low_name == "Alice" or &1.user_high_name == "Alice"))
    # Every row is live: an unmatch deletes, so there is nothing else it could be.
    assert Enum.all?(rows, & &1.active)
  end

  @tag :postgres_integration
  test "search finds a pair by either participant's id" do
    alice = user!("Alice Searchable")
    bob = user!("Bob Searchable")
    match!(alice, bob, 1)
    match!(user!("Other One"), user!("Other Two"), 2)

    assert {:ok, %{matches: rows}} =
             DatingAdmin.list_matches(%{"app_id" => @app_id, "q" => alice})

    assert length(rows) == 1
    assert alice in [hd(rows).user_low_id, hd(rows).user_high_id]
  end
end
