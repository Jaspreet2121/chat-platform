defmodule AuthService.TestTwinRaceTest do
  @moduledoc """
  The test-twin find-or-create's atomicity — the TOCTOU flagged when test/live keys shipped.

  CORRECTED PREMISE, established in this slice's report: the shipped code already survived the race
  (unique_violation + re-select, backed by the REAL partial index `apps_test_twin_unique`, 054) —
  but with ZERO test coverage: the retry branch had never executed anywhere. These tests cover the
  recorded ON CONFLICT shape that replaced it, including the branch trap 1 names: ON CONFLICT DO
  NOTHING returns ZERO rows for exactly the raced case, so the guaranteed follow-up SELECT is
  load-bearing, not defensive.

  `allocate_twin/1` is public (@doc false — the commit_decision precedent) because the raced branch
  is unreachable through the public API without a genuine concurrent loser.
  """
  use AuthService.DataCase, async: false

  alias AuthService.ApiKeys

  defp live_app! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO apps (id, name, slug, mode) VALUES ($1::text::uuid, $2, $3, 'live')",
      [
        id,
        "Acme #{System.unique_integer([:positive])}",
        "acme-#{System.unique_integer([:positive])}"
      ]
    )

    id
  end

  defp twin_rows(live_app_id) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM apps WHERE parent_app_id = $1::text::uuid AND mode = 'test'",
        [live_app_id]
      )

    n
  end

  @tag :postgres_integration
  test "(a) two concurrent allocations yield ONE twin and both callers get its id" do
    live = live_app!()
    parent = self()

    # Both tasks run the FULL miss path (no fast-path SELECT): the first inserts, the second hits
    # the ON CONFLICT and takes the guaranteed-SELECT branch. The sandbox serializes them onto one
    # connection, which is fine — the property under test is the STATEMENT's atomicity, not
    # scheduler interleaving.
    for i <- 1..2 do
      Task.start(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
        send(parent, {:twin, i, ApiKeys.allocate_twin(live)})
      end)
    end

    results =
      for _ <- 1..2 do
        receive do
          {:twin, _i, result} -> result
        after
          5_000 -> flunk("allocation did not complete")
        end
      end

    assert [{:ok, twin_a}, {:ok, twin_b}] = Enum.sort(results)
    assert twin_a == twin_b
    assert twin_rows(live) == 1
  end

  @tag :postgres_integration
  test "(b) THE RACED BRANCH: conflict fired, RETURNING empty — the follow-up SELECT still answers" do
    live = live_app!()

    # The winner already exists…
    {:ok, existing} = ApiKeys.allocate_twin(live)

    # …so this allocation is the raced LOSER by construction: ON CONFLICT fires, RETURNING yields
    # zero rows, and only the guaranteed SELECT can produce the answer.
    assert {:ok, ^existing} = ApiKeys.allocate_twin(live)
    assert twin_rows(live) == 1
  end

  @tag :postgres_integration
  test "(c) a second sequential key creation reuses the twin — same app_id, no new row" do
    live = live_app!()

    {:ok, key1} = ApiKeys.create_api_key(%{"app_id" => live, "name" => "t1", "mode" => "test"})
    {:ok, key2} = ApiKeys.create_api_key(%{"app_id" => live, "name" => "t2", "mode" => "test"})

    assert key1.app_id == key2.app_id
    refute key1.app_id == live
    assert twin_rows(live) == 1
  end

  @tag :postgres_integration
  test "(d) the constraint pin: a second twin row for the same parent CANNOT be inserted" do
    live = live_app!()
    {:ok, _} = ApiKeys.allocate_twin(live)

    # Straight past the application code: the partial unique index is what makes duplicate twins
    # impossible even for a writer that ignores every convention. A duplicate twin would SPLIT an
    # integrator's test data across two app_ids silently — this raise is the floor under all of it.
    assert_raise Postgrex.Error, ~r/unique|apps_test_twin_unique/, fn ->
      Repo.query!(
        "INSERT INTO apps (id, name, slug, parent_app_id, mode) " <>
          "VALUES (gen_random_uuid(), 'dup', $2, $1::text::uuid, 'test')",
        [live, "dup-#{System.unique_integer([:positive])}"]
      )
    end
  end

  @tag :postgres_integration
  test "a nonexistent live app cannot allocate a twin" do
    assert {:error, :api_key_invalid} = ApiKeys.allocate_twin(Ecto.UUID.generate())
  end

  @tag :postgres_integration
  test "the billing filter survives: the twin carries parent_app_id + mode='test'" do
    live = live_app!()
    {:ok, twin} = ApiKeys.allocate_twin(live)

    # Metering excludes test apps by exactly these two columns; the atomicity change must leave
    # them intact (trap 4).
    %{rows: [[parent, mode]]} =
      Repo.query!("SELECT parent_app_id::text, mode FROM apps WHERE id = $1::text::uuid", [twin])

    assert parent == live
    assert mode == "test"
  end
end
