defmodule UserService.NearbyPureTest do
  @moduledoc """
  The pure rules behind Nearby's 8-hour "stay visible" mode (114), tested without a database so the
  boundaries are pinned by name rather than inferred from SQL.

  These three functions carry the privacy properties of the feature: what a viewer learns about
  staleness, and whether a bucket pin can be shaken loose.
  """
  use ExUnit.Case, async: true

  alias UserService.Nearby

  describe "staleness_bucket/1 — coarse ceilings, never a timestamp" do
    test "everything under ten minutes reads as 'now'" do
      # The floor is deliberately wide: it absorbs the publish cadence, so a viewer cannot infer how
      # often a phone reports by watching the label change.
      for age <- [0, 1, 59, 300, 599, 600], do: assert(Nearby.staleness_bucket(age) == "now")
    end

    test "each boundary belongs to the bucket it names (ceilings, not floors)" do
      assert Nearby.staleness_bucket(600) == "now"
      assert Nearby.staleness_bucket(601) == "1h"
      assert Nearby.staleness_bucket(3_600) == "1h"
      assert Nearby.staleness_bucket(3_601) == "2h"
      assert Nearby.staleness_bucket(7_200) == "2h"
      assert Nearby.staleness_bucket(7_201) == "4h"
      assert Nearby.staleness_bucket(14_400) == "4h"
      assert Nearby.staleness_bucket(14_401) == "8h"
    end

    test "the retention edge and anything past it read as '8h'" do
      assert Nearby.staleness_bucket(28_800) == "8h"
      # A row older than the TTL should have been deleted; if one is ever seen it must not read fresh.
      assert Nearby.staleness_bucket(999_999) == "8h"
    end

    test "the five labels are DISTINCT and there are exactly five" do
      labels =
        [0, 601, 3_601, 7_201, 14_401]
        |> Enum.map(&Nearby.staleness_bucket/1)

      assert labels == ["now", "1h", "2h", "4h", "8h"]
      assert length(Enum.uniq(labels)) == 5
    end

    test "never returns a number, and never crashes on junk" do
      for value <- [nil, "x", -5, :bad] do
        assert is_binary(Nearby.staleness_bucket(value))
      end
    end
  end

  describe "pin_key/2 — the anti-trilateration property" do
    test "the key is scoped to the TARGET's fix, not the viewer's position" do
      # A viewer has one identity and one key per target-fix. Nothing about where the VIEWER stands
      # enters the key, which is exactly why moving does not let them re-roll the bucket.
      assert Nearby.pin_key("viewer-1", 7) == Nearby.pin_key("viewer-1", 7)
      refute Nearby.pin_key("viewer-1", 7) == Nearby.pin_key("viewer-1", 8)
      refute Nearby.pin_key("viewer-1", 7) == Nearby.pin_key("viewer-2", 7)
    end
  end

  describe "new_fix?/3 — what retires a pin" do
    @delhi_lat 28.6139
    @delhi_lng 77.2090

    test "no previous fix is always new" do
      assert Nearby.new_fix?(nil, @delhi_lat, @delhi_lng)
    end

    test "GPS jitter and a stationary re-publish do NOT advance the fix" do
      # ~11 m north. Under the threshold, so pins survive: a phone sitting still cannot be used to
      # shake a viewer's pinned bucket loose by republishing.
      refute Nearby.new_fix?({@delhi_lat, @delhi_lng}, @delhi_lat + 0.0001, @delhi_lng)
      refute Nearby.new_fix?({@delhi_lat, @delhi_lng}, @delhi_lat, @delhi_lng)
    end

    test "a real move DOES advance the fix" do
      # ~111 m north — comfortably past the 25 m threshold.
      assert Nearby.new_fix?({@delhi_lat, @delhi_lng}, @delhi_lat + 0.001, @delhi_lng)
      assert Nearby.new_fix?({@delhi_lat, @delhi_lng}, @delhi_lat + 0.5, @delhi_lng)
    end

    test "the threshold sits between jitter and a real move" do
      # Bracketing it rather than asserting the constant: ~5.5 m stays, ~55 m goes.
      refute Nearby.new_fix?({@delhi_lat, @delhi_lng}, @delhi_lat + 0.00005, @delhi_lng)
      assert Nearby.new_fix?({@delhi_lat, @delhi_lng}, @delhi_lat + 0.0005, @delhi_lng)
    end
  end

  describe "bounding_box/3 — the superset property" do
    # THE ONE CORRECTNESS REQUIREMENT. The box is a scan prefilter, not the membership test: the
    # haversine still decides. So the box may be generous, but it must NEVER exclude a point the
    # haversine would have accepted — that would silently drop real neighbours.
    #
    # Property-style: sweep bearings around each centre and place a point just inside the radius,
    # then assert the box contains it. Deterministic (no randomness), so a failure reproduces.

    @earth 6_371_000.0

    defp offset(lat, lng, distance_m, bearing_deg) do
      br = bearing_deg * :math.pi() / 180.0
      dlat = distance_m * :math.cos(br) / @earth * 180.0 / :math.pi()
      cos_lat = :math.cos(lat * :math.pi() / 180.0)
      dlng =
        if abs(cos_lat) < 1.0e-9,
          do: 0.0,
          else: distance_m * :math.sin(br) / (@earth * cos_lat) * 180.0 / :math.pi()

      {lat + dlat, lng + dlng}
    end

    defp inside_box?({min_lat, max_lat, min_lng, max_lng}, {lat, lng}) do
      lat >= min_lat and lat <= max_lat and lng >= min_lng and lng <= max_lng
    end

    test "a point just inside the radius is NEVER excluded — every bearing, both bands, many latitudes" do
      centres = [
        {0.0, 0.0},
        {28.6139, 77.2090},
        {51.5074, -0.1278},
        {-33.8688, 151.2093},
        {60.0, 25.0},
        {-60.0, -70.0},
        {75.0, 10.0},
        {-75.0, 120.0}
      ]

      for {lat, lng} <- centres,
          radius <- [100, 200],
          bearing <- 0..359//5,
          fraction <- [0.5, 0.9, 0.999, 1.0] do
        box = Nearby.bounding_box(lat, lng, radius * 1.0)
        point = offset(lat, lng, radius * fraction, bearing)

        assert inside_box?(box, point),
               "radius #{radius} bearing #{bearing} at #{inspect({lat, lng})}: " <>
                 "#{inspect(point)} fell outside #{inspect(box)}"
      end
    end

    test "the pole guard opens the longitude range fully where cos(lat) collapses" do
      # cos(lat) -> 0 makes the longitude half-width diverge, so past ~89.43 degrees the guard opens
      # the range entirely. That is a superset AND geometrically right: that close to a pole, a 200 m
      # circle really does span every meridian.
      for lat <- [89.5, 89.9, 90.0, -89.9, -90.0] do
        {_min_lat, _max_lat, min_lng, max_lng} = Nearby.bounding_box(lat, 0.0, 200.0)
        assert {min_lng, max_lng} == {-180.0, 180.0}, "lat #{lat} should clamp"
      end
    end

    test "below the guard the box stays finite — and the sweep above proves it is still a superset" do
      # 89.0 does NOT clamp (cos ~= 0.0175), and it does not need to: a finite but correctly widened
      # box covers the circle there. Pinned so a future tweak to the guard threshold is deliberate.
      {_, _, min_lng, max_lng} = Nearby.bounding_box(89.0, 0.0, 200.0)

      assert min_lng > -180.0 and max_lng < 180.0
      assert max_lng - min_lng > 0.1, "longitude must widen a lot at 89 degrees"
    end

    test "latitude never leaves [-90, 90]" do
      for lat <- [90.0, -90.0, 89.999, -89.999] do
        {min_lat, max_lat, _, _} = Nearby.bounding_box(lat, 0.0, 200.0)
        assert min_lat >= -90.0 and max_lat <= 90.0
      end
    end

    test "the box is a PROPER superset — it is bigger than the radius, not a tight fit" do
      # If it were tight, floating-point error alone could clip an edge point.
      {min_lat, max_lat, _, _} = Nearby.bounding_box(0.0, 0.0, 200.0)
      lat_span_m = (max_lat - min_lat) / 180.0 * :math.pi() * @earth

      assert lat_span_m > 400.0, "span #{lat_span_m} m must exceed the 400 m diameter"
    end

    test "a bigger radius yields a bigger box" do
      {min_100, max_100, _, _} = Nearby.bounding_box(28.6139, 77.2090, 100.0)
      {min_200, max_200, _, _} = Nearby.bounding_box(28.6139, 77.2090, 200.0)

      assert max_200 - min_200 > max_100 - min_100
    end
  end
end
