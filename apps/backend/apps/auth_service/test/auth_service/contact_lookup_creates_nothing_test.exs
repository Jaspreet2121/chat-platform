defmodule AuthService.ContactLookupCreatesNothingTest do
  @moduledoc """
  THE INVARIANT behind the shadow-account cleanup: a users_auth row is created by an OTP verify
  (or the v1 token exchange) and by NOTHING ELSE. Contact matching is a read.

  Pinned on real SQL because the cleanup deletes rows that match "never verified, no profile" —
  if any read path started minting accounts for unknown numbers, the next sync would refill the
  set the migration just emptied.
  """
  use AuthService.DataCase, async: false

  alias AuthService.Accounts

  @tenant "00000000-0000-0000-0000-000000000001"

  defp count_users do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM users_auth")
    n
  end

  @tag :postgres_integration
  test "a contact sync with 10 UNKNOWN numbers creates no users_auth row" do
    before = count_users()
    unknown = for i <- 1..10, do: "+1555#{System.unique_integer([:positive])}#{i}"

    assert {:ok, []} = Accounts.lookup_active_by_phones(unknown, @tenant)

    assert count_users() == before,
           "a contact sync minted #{count_users() - before} account(s) for numbers nobody has " <>
             "verified — the shadow set refills on every sync"
  end

  @tag :postgres_integration
  test "a number that IS a real, discoverable user still matches" do
    id = Ecto.UUID.generate()
    phone = "+1555#{System.unique_integer([:positive])}"

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active')",
      [id, @tenant, phone]
    )

    assert {:ok, [match]} = Accounts.lookup_active_by_phones([phone, "+15550000000"], @tenant)
    # Whatever the match's key for the id is, it names THIS user and nobody else.
    assert inspect(match) =~ id
  end
end
