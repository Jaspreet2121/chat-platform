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
  test "the PAGE SIZE IS THE SERVER'S — a caller may narrow it, never widen it" do
    anchor = user!("Anchor")
    for i <- 1..60, do: match!(anchor, user!("Peer #{i}"), i)

    # Ask for far more than the cap.
    assert {:ok, %{matches: matches, page_size: size}} =
             DatingAdmin.list_matches(%{"app_id" => @app_id, "limit" => "10000"})

    assert length(matches) == DatingAdmin.page_size()
    assert size == DatingAdmin.page_size()

    # Junk, zero and negative all land on the server's size rather than disabling the bound.
    for bad <- ["0", "-1", "abc", nil] do
      assert {:ok, %{matches: rows}} =
               DatingAdmin.list_matches(%{"app_id" => @app_id, "limit" => bad})

      assert length(rows) == DatingAdmin.page_size()
    end

    # Narrowing IS allowed.
    assert {:ok, %{matches: five}} =
             DatingAdmin.list_matches(%{"app_id" => @app_id, "limit" => "5"})

    assert length(five) == 5
  end

  @tag :postgres_integration
  test "cursor paging walks the whole list once — no skips, no repeats" do
    anchor = user!("Anchor")
    for i <- 1..12, do: match!(anchor, user!("Peer #{i}"), i)

    {:ok, page1} = DatingAdmin.list_matches(%{"app_id" => @app_id, "limit" => "5"})
    assert length(page1.matches) == 5
    assert is_binary(page1.next_cursor)

    {:ok, page2} =
      DatingAdmin.list_matches(%{
        "app_id" => @app_id,
        "limit" => "5",
        "cursor" => page1.next_cursor
      })

    {:ok, page3} =
      DatingAdmin.list_matches(%{
        "app_id" => @app_id,
        "limit" => "5",
        "cursor" => page2.next_cursor
      })

    ids = Enum.map(page1.matches ++ page2.matches ++ page3.matches, & &1.id)
    assert length(ids) == 12
    assert length(Enum.uniq(ids)) == 12
    # The last page knows it is the last.
    assert is_nil(page3.next_cursor)
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
