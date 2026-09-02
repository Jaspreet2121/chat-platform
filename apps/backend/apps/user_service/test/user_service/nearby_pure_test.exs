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
end
