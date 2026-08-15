defmodule AuthService.OwnsAppTwinTest do
  @moduledoc """
  The gap-4 auth widening, proven exactly as wide as intended: `Apps.owns_app/1` grants an owner
  their live app's TEST TWIN through `parent_app_id` + `mode='test'` — one hop, downward only.

  (a) owner reads through to the twin; (b) a foreign owner still gets :forbidden on someone
  else's twin; (c) an owner row ON a twin (contrived — none exist in production) grants the twin
  itself and NEVER the parent. Plus the two leaf guards the widening made reachable: a test key
  against a twin cannot allocate a twin-of-twin, and a live key cannot land on a twin.

  Tagged :postgres_integration — needs a real DB.
  """
  use ExUnit.Case, async: false

  alias AuthService.ApiKeys
  alias AuthService.Apps
  alias AuthService.Repo

  setup do
    start_repo!()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  @tag :postgres_integration
  test "(a) owning the live app grants its twin; the direct branch is unchanged" do
    %{app: app, owner: owner, twin: twin} = seed_owned_app_with_twin()

    assert {:ok, %{app_id: ^app}} = owns(app, owner)
    # THE WIDENING: the twin resolves through parent_app_id to an app_owners row on the parent.
    assert {:ok, %{app_id: ^twin}} = owns(twin, owner)
  end

  @tag :postgres_integration
  test "(b) a foreign owner is still :forbidden on someone else's twin (and parent)" do
    %{twin: twin, app: app} = seed_owned_app_with_twin()
    %{owner: foreign} = seed_owned_app_with_twin()

    assert {:error, :forbidden} = owns(twin, foreign)
    assert {:error, :forbidden} = owns(app, foreign)
    # The pre-widening refusals hold: nonexistent and malformed ids never leak.
    assert {:error, :forbidden} = owns(Ecto.UUID.generate(), foreign)
    assert {:error, :forbidden} = owns("not-a-uuid", foreign)
  end

  @tag :postgres_integration
  test "(c) DOWNWARD-ONLY: an owner row ON a twin grants the twin, never the parent" do
    %{app: app, twin: twin} = seed_owned_app_with_twin()

    # Contrived: production never writes app_owners rows for twins; the guard must be structural.
    twin_owner = insert_user!(app)

    Repo.query!(
      "INSERT INTO app_owners (app_id, owner_user_id, role) VALUES ($1::text::uuid, $2::text::uuid, 'owner')",
      [twin, twin_owner]
    )

    assert {:ok, %{app_id: ^twin}} = owns(twin, twin_owner)
    # Twin ownership NEVER flows upward — the parent requires its own app_owners row.
    assert {:error, :forbidden} = owns(app, twin_owner)
  end

  @tag :postgres_integration
  test "twins are leaves: no twin-of-twin allocation, no live key on a twin" do
    %{app: app, twin: twin} = seed_owned_app_with_twin()

    # A test key naming the TWIN as target must refuse — not allocate a second generation.
    assert {:error, :api_key_invalid} =
             ApiKeys.create_api_key(%{"app_id" => twin, "name" => "nope", "mode" => "test"})

    %{rows: [[descendants]]} =
      Repo.query!("SELECT count(*)::int FROM apps WHERE parent_app_id = $1::text::uuid", [twin])

    assert descendants == 0

    # A live key naming the twin must refuse — no sk_live_ credential on a test tenant.
    assert {:error, :api_key_invalid} =
             ApiKeys.create_api_key(%{"app_id" => twin, "name" => "nope", "mode" => "live"})

    # Sanity: the normal paths are intact — test key on the PARENT lands on the twin, live on live.
    assert {:ok, %{app_id: ^twin, mode: "test"}} =
             ApiKeys.create_api_key(%{"app_id" => app, "name" => "ok", "mode" => "test"})

    assert {:ok, %{app_id: ^app, mode: "live"}} =
             ApiKeys.create_api_key(%{"app_id" => app, "name" => "ok", "mode" => "live"})
  end

  # --- seed ------------------------------------------------------------------------------------

  defp owns(app_id, owner_user_id),
    do: Apps.owns_app(%{"app_id" => app_id, "owner_user_id" => owner_user_id})

  defp seed_owned_app_with_twin do
    app = insert_app!("live", nil)
    twin = insert_app!("test", app)
    owner = insert_user!(app)

    Repo.query!(
      "INSERT INTO app_owners (app_id, owner_user_id, role) VALUES ($1::text::uuid, $2::text::uuid, 'owner')",
      [app, owner]
    )

    %{app: app, twin: twin, owner: owner}
  end

  defp insert_app!(mode, parent_app_id) do
    id = uuid()

    Repo.query!(
      "INSERT INTO apps (id, name, slug, mode, parent_app_id) " <>
        "VALUES ($1::text::uuid, $2, $3, $4, $5::text::uuid)",
      [id, "walkfix-#{uniq()}", "walkfix-#{uniq()}", mode, parent_app_id]
    )

    id
  end

  defp insert_user!(app_id) do
    id = uuid()

    Repo.query!(
      "INSERT INTO users_auth (id, email, status, app_id) VALUES ($1::text::uuid, $2, 'active', $3::text::uuid)",
      [id, "u#{uniq()}@example.test", app_id]
    )

    id
  end

  defp uuid, do: Ecto.UUID.generate()
  defp uniq, do: System.unique_integer([:positive])

  defp start_repo! do
    case Repo.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end
end
