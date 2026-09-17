defmodule SharedInfra.Utf16Test do
  @moduledoc """
  UTF-16 code units — the unit a JS/Kotlin/Swift client counts when it builds entity offsets, and
  the one Elixir has neither of built in. The emoji cases are the whole point: bytes, codepoints and
  UTF-16 units disagree there, and picking the wrong one silently accepts or rejects valid spans.
  """
  use ExUnit.Case, async: true

  alias SharedInfra.Utf16

  describe "length/1" do
    test "ASCII: all three measures agree" do
      assert Utf16.length("hello") == 5
      assert byte_size("hello") == 5
      assert String.length("hello") == 5
    end

    test "an EMOJI is TWO units — one codepoint, four bytes, a surrogate pair" do
      assert Utf16.length("😀") == 2
      assert String.length("😀") == 1
      assert byte_size("😀") == 4
    end

    test "accented Latin and Devanagari are ONE unit each, though they are 2 and 3 bytes" do
      assert Utf16.length("é") == 1
      assert byte_size("é") == 2

      assert Utf16.length("क") == 1
      assert byte_size("क") == 3

      # नमस्ते — a FOURTH measure disagrees here: six codepoints (so six UTF-16 units) over eighteen
      # bytes render as only a handful of grapheme clusters. Entities index units, never graphemes.
      #
      # The cluster COUNT is deliberately not pinned. Grapheme segmentation comes from the Unicode
      # tables bundled with the Elixir release, and this very string moved from 4 clusters to 3 when
      # the conjunct-cluster rule joined स ् त: CI's Elixir 1.18.4 ships Unicode 16 and answers 4,
      # Elixir 1.20.1 ships Unicode 17 and answers 3. The old `== 3` here therefore asserted the
      # standard library's VERSION rather than this module's behaviour, and is exactly why this test
      # passed on a developer machine and failed on CI. The inequality is the part that is actually
      # true everywhere, and it is the part the entity rules depend on.
      assert Utf16.length("नमस्ते") == 6
      assert length(String.to_charlist("नमस्ते")) == 6
      assert byte_size("नमस्ते") == 18
      assert String.length("नमस्ते") < Utf16.length("नमस्ते")
    end

    test "a mixed body: the count is the sum of per-codepoint widths" do
      # "hi 😀!" → h,i,space = 3, emoji = 2, ! = 1
      assert Utf16.length("hi 😀!") == 6
      assert String.length("hi 😀!") == 5
    end

    test "empty and non-binary measure zero" do
      assert Utf16.length("") == 0
      assert Utf16.length(nil) == 0
      assert Utf16.length(42) == 0
    end
  end

  describe "the E2EE_FRAME §11.4 fixture" do
    # The documented sealed-frame fixture, so the doc and this code cannot drift apart. Verified
    # against a real UTF-16 engine: in JS, "hello 😀 secret".length === 15, .indexOf("secret") === 9.
    @fixture_body "hello 😀 secret"

    test "the body measures 15 units and the documented spans land on the documented words" do
      assert Utf16.length(@fixture_body) == 15

      # bold 0..5 is "hello"; spoiler 9..15 is "secret" — one unit later than a codepoint count
      # would have put it, because the emoji is a surrogate pair.
      assert Utf16.mask_ranges(@fixture_body, [{0, 5}], "▒") == "▒▒▒▒▒ 😀 secret"
      assert Utf16.mask_ranges(@fixture_body, [{9, 6}], "▒") == "hello 😀 ▒▒▒▒▒▒"

      # The codepoint-counted offset (8) would mask the space and lose the final letter.
      refute Utf16.mask_ranges(@fixture_body, [{8, 6}], "▒") == "hello 😀 ▒▒▒▒▒▒"
    end
  end

  describe "mask_ranges/3" do
    test "masks exactly the range, one block per character" do
      assert Utf16.mask_ranges("the answer is 42", [{14, 2}], "▒") == "the answer is ▒▒"
      assert Utf16.mask_ranges("abcdef", [{0, 3}], "▒") == "▒▒▒def"
    end

    test "an emoji INSIDE the masked span counts as two units but masks to ONE block" do
      # "ab😀cd": a=0 b=1 emoji=2..3 c=4 d=5
      assert Utf16.mask_ranges("ab😀cd", [{2, 2}], "▒") == "ab▒cd"
      # A span covering b + the emoji (units 1..3).
      assert Utf16.mask_ranges("ab😀cd", [{1, 3}], "▒") == "a▒▒cd"
    end

    test "an emoji BEFORE the span shifts the offsets by two, not one" do
      # "😀secret": emoji occupies units 0..1, so "secret" starts at unit 2.
      assert Utf16.mask_ranges("😀secret", [{2, 6}], "▒") == "😀▒▒▒▒▒▒"
      # Counting codepoints instead (offset 1) would mask one character too early.
      refute Utf16.mask_ranges("😀secret", [{1, 6}], "▒") == "😀▒▒▒▒▒▒"
    end

    test "multiple, overlapping, unordered and out-of-range spans all behave" do
      assert Utf16.mask_ranges("abcdef", [{4, 2}, {0, 2}], "▒") == "▒▒cd▒▒"
      assert Utf16.mask_ranges("abcdef", [{0, 3}, {2, 3}], "▒") == "▒▒▒▒▒f"
      # Clipped at the end; entirely past the end is a no-op.
      assert Utf16.mask_ranges("abc", [{1, 99}], "▒") == "a▒▒"
      assert Utf16.mask_ranges("abc", [{99, 5}], "▒") == "abc"
    end

    test "no ranges, zero length, and malformed ranges leave the text alone" do
      assert Utf16.mask_ranges("abc", [], "▒") == "abc"
      assert Utf16.mask_ranges("abc", [{1, 0}], "▒") == "abc"
      assert Utf16.mask_ranges("abc", [{-1, 2}], "▒") == "abc"
      assert Utf16.mask_ranges("abc", ["nonsense"], "▒") == "abc"
      assert Utf16.mask_ranges(nil, [{0, 1}], "▒") == nil
    end
  end
end
