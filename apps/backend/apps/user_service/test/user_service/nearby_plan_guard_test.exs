defmodule UserService.NearbyPlanGuardTest do
  @moduledoc """
  The Nearby discover query must be carried by the bounding-box index, and the box must be small.

  Before 114 the query was a Haversine over every live row in the app — a full scan whose cost
  grew with every opted-in user. 114 added the (app_id, latitude) INCLUDE (longitude) index and the
  box predicates; on 20,000 synthetic rows the plan went from a Seq Scan removing 20,000 rows
  (4.8 ms) to an Index Scan examining 134 (0.11 ms). Nothing pinned that, so a rewrite of the SQL
  or a dropped index would have brought the full scan back silently, one release at a time.

  This EXPLAINs the REAL statement — `Nearby.discover_sql/0`, not a copy — over 6,000 synthetic
  publishers and asserts two things the planner cannot fake: the index is used, and the latitude
  band it walks is a small fraction of the table. The second is what catches a box that quietly
  widened to the whole world: the index would still be "used" and the scan would still be total.
  """
  use UserService.DataCase, async: false

  alias UserService.Nearby

  @tenant "00000000-0000-0000-0000-000000000001"
  @rows 6_000
  @lat 28.6
  @lng 77.2

  defp seed! do
    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status) " <>
        "SELECT gen_random_uuid(), $1::text::uuid, '+1900' || g, 'active' FROM generate_series(1, $2) g",
      [@tenant, @rows]
    )

    # Spread over ~65 km around one point, all live for the whole 8h window.
    Repo.query!(
      "INSERT INTO nearby_presence (user_id, app_id, latitude, longitude, accuracy_m, expires_at, updated_at) " <>
        "SELECT u.id, u.app_id, $1 + (random() - 0.5) * 0.6, $2 + (random() - 0.5) * 0.6, 10, " <>
        "now() + interval '8 hours', now() FROM users_auth u WHERE u.phone_number LIKE '+1900%'",
      [@lat, @lng]
    )

    Repo.query!("ANALYZE nearby_presence", [])
    Repo.query!("ANALYZE users_auth", [])
  end

  # Every node in the plan tree, flattened.
  defp nodes(%{"Plans" => children} = node), do: [node | Enum.flat_map(children, &nodes/1)]
  defp nodes(node), do: [node]

  @tag :postgres_integration
  test "discover is carried by nearby_presence_bbox_idx and walks only the latitude band" do
    seed!()
    viewer = Ecto.UUID.generate()
    {min_lat, max_lat, min_lng, max_lng} = Nearby.bounding_box(@lat, @lng, 200.0)

    %Postgrex.Result{rows: [[[%{"Plan" => plan}]]]} =
      Repo.query!(
        "EXPLAIN (ANALYZE, FORMAT JSON) " <> Nearby.discover_sql(),
        [viewer, @tenant, @lat, @lng, 200.0, "everyone", min_lat, max_lat, min_lng, max_lng]
      )

    presence_nodes = plan |> nodes() |> Enum.filter(&(&1["Relation Name"] == "nearby_presence"))
    assert presence_nodes != [], "no scan of nearby_presence in the plan at all"

    # 1. THE INDEX carries it. A Seq Scan on the presence table is the pre-114 full scan.
    refute Enum.any?(presence_nodes, &(&1["Node Type"] == "Seq Scan")),
           "nearby_presence is being sequentially scanned"

    assert Enum.any?(presence_nodes, &(&1["Index Name"] == "nearby_presence_bbox_idx")),
           "nearby_presence_bbox_idx is not used: #{inspect(Enum.map(presence_nodes, & &1["Node Type"]))}"

    # 2. THE BAND is narrow. Rows the index handed to the filter, i.e. the latitude range — a box
    #    that widened to the world would still "use the index" and examine every row.
    examined =
      presence_nodes
      |> Enum.map(&((&1["Actual Rows"] || 0) + (&1["Rows Removed by Filter"] || 0)))
      |> Enum.max()

    assert examined < div(@rows, 10),
           "the index walked #{examined} of #{@rows} rows — the bounding box is not narrowing the scan"
  end
end
