defmodule SharedInfra.AdminCursorTest do
  @moduledoc """
  The one keyset implementation every admin list pages through, tested as pure logic.

  Two properties carry the feature. First, PAGE SIZE IS THE SERVER'S: a caller may narrow a page and
  can never widen it, which is the only thing separating a list endpoint over personal data from an
  export endpoint. Second, the cursors are honest about which directions exist — the UI disables its
  buttons on a nil, so a cursor handed back for a page that isn't there is a button that lies.
  """
  use ExUnit.Case, async: true

  alias SharedInfra.AdminCursor

  describe "clamp/1" do
    test "a caller may ask for a smaller page" do
      assert AdminCursor.clamp(10) == 10
      assert AdminCursor.clamp("10") == 10
    end

    test "a caller can NEVER ask for a bigger one" do
      # This is the whole defence. min/2, not the caller's number.
      assert AdminCursor.clamp(5_000) == AdminCursor.page_size()
      assert AdminCursor.clamp("5000") == AdminCursor.page_size()
    end

    test "absent, zero, negative and junk all get the default" do
      for value <- [nil, 0, -1, "0", "-3", "abc", "", %{}] do
        assert AdminCursor.clamp(value) == AdminCursor.page_size()
      end
    end
  end

  describe "decode/1" do
    test "round-trips a timestamp and an id" do
      cursor = AdminCursor.encode("2026-09-25T10:00:00Z", "11111111-1111-1111-1111-111111111111")

      assert {:ok, {"2026-09-25T10:00:00Z", "11111111-1111-1111-1111-111111111111"}} =
               AdminCursor.decode(cursor)
    end

    test "a malformed cursor is the FIRST PAGE, never an error" do
      # A bookmark from an older shape of the list should show a list, not a 400 the reader cannot act on.
      for value <- [nil, "", "nonsense", "|", "ts|", "|id", 42] do
        assert AdminCursor.decode(value) == :none
      end
    end
  end

  describe "where/4 and order/3" do
    test "forward reads DESC past the cursor; backward reads ASC before it" do
      assert AdminCursor.where(:next, "t", "i", 2) ==
               "(t, i) < ($3::text::timestamptz, $4::text::uuid)"

      assert AdminCursor.where(:prev, "t", "i", 0) ==
               "(t, i) > ($1::text::timestamptz, $2::text::uuid)"

      assert AdminCursor.order(:next, "t", "i") == "ORDER BY t DESC, i DESC"
      # Reading DESC from a "greater than" cursor would return the newest rows on the platform
      # instead of the page before this one.
      assert AdminCursor.order(:prev, "t", "i") == "ORDER BY t ASC, i ASC"
    end

    test "the double cast survives, because Postgrex sends a bare string as text" do
      assert AdminCursor.where(:next, "t", "i", 0) =~ "::text::timestamptz"
      assert AdminCursor.where(:next, "t", "i", 0) =~ "::text::uuid"
    end
  end

  describe "to_page/5" do
    # Rows are {ts, id}; the extractor is the identity so the assertions read clearly.
    defp rows(n, from \\ 1) do
      for i <- from..(from + n - 1),
          do: {"2026-09-#{String.pad_leading("#{i}", 2, "0")}", "id-#{i}"}
    end

    defp extract, do: fn row -> row end

    test "the first page keeps page_size rows and offers no way back" do
      page = AdminCursor.to_page(rows(4), :next, false, 3, extract())

      assert length(page.items) == 3
      assert page.prev_cursor == nil
      # The 4th row was fetched only to answer "is there more?" — it must not be served.
      refute Enum.any?(page.items, &match?({_, "id-4"}, &1))
      assert page.next_cursor == AdminCursor.encode("2026-09-03", "id-3")
    end

    test "the LAST page offers no way forward" do
      page = AdminCursor.to_page(rows(2), :next, true, 3, extract())

      assert length(page.items) == 2

      # No extra row => nothing ahead. A cursor here would be a Next button that loads an empty page.
      assert page.next_cursor == nil
      assert page.prev_cursor == AdminCursor.encode("2026-09-01", "id-1")
    end

    test "paging BACKWARDS flips the rows so the caller always sees newest-first" do
      # Read ascending from the cursor: 3, 4, 5 (+1 extra).
      ascending = [
        {"2026-09-03", "id-3"},
        {"2026-09-04", "id-4"},
        {"2026-09-05", "id-5"},
        {"2026-09-06", "id-6"}
      ]

      page = AdminCursor.to_page(ascending, :prev, true, 3, extract())

      assert page.items == [
               {"2026-09-05", "id-5"},
               {"2026-09-04", "id-4"},
               {"2026-09-03", "id-3"}
             ]

      # We came FROM a later page, so there is always one ahead.
      assert page.next_cursor == AdminCursor.encode("2026-09-03", "id-3")
      # The extra row means there is still something behind.
      assert page.prev_cursor == AdminCursor.encode("2026-09-05", "id-5")
    end

    test "paging back to the very first page offers no further back" do
      page = AdminCursor.to_page(rows(2), :prev, true, 3, extract())
      assert page.prev_cursor == nil
      assert page.next_cursor != nil
    end

    test "an empty result yields no cursors in either direction" do
      page = AdminCursor.to_page([], :next, true, 3, extract())
      assert page.items == []
      assert page.next_cursor == nil
      assert page.prev_cursor == nil
    end
  end
end
