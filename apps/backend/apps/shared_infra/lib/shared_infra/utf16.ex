defmodule SharedInfra.Utf16 do
  @moduledoc """
  UTF-16 code-unit arithmetic over Elixir's UTF-8 binaries.

  WHY THIS EXISTS: rich-text `entities` (offset/length spans over a message body) are indexed in
  UTF-16 code units, because that is what the clients that produce them count — Java/Kotlin
  `String.length`, JavaScript `String.prototype.length` and Swift's `utf16.count` are all UTF-16.
  Elixir's `byte_size/1` (UTF-8 bytes) and `String.length/1` (codepoints) are BOTH different, and
  the three only agree on ASCII:

      "a"   → bytes 1, codepoints 1, utf16 1
      "é"   → bytes 2, codepoints 1, utf16 1
      "क"   → bytes 3, codepoints 1, utf16 1
      "😀"  → bytes 4, codepoints 1, utf16 2   ← a surrogate PAIR

  Validating an offset against the wrong one accepts spans that overrun the body on the client (a
  crash or a mangled render) or rejects spans that are perfectly in range. Everything here counts
  units: a codepoint below U+10000 is one unit, U+10000 and above is two (the surrogate pair).
  """

  @doc """
  The length of `text` in UTF-16 code units — what `"…".length` answers in JS/Java/Kotlin.

      iex> SharedInfra.Utf16.length("hi")
      2
      iex> SharedInfra.Utf16.length("😀")
      2
  """
  @spec length(binary()) :: non_neg_integer()
  def length(text) when is_binary(text) do
    text
    |> to_codepoints()
    |> Enum.reduce(0, fn codepoint, total -> total + units(codepoint) end)
  end

  def length(_text), do: 0

  @doc """
  Replace every UTF-16 `{offset, length}` range in `ranges` with `mask`, one mask character per
  CODEPOINT covered (not per unit — an emoji is one glyph, so it masks to one block, and the result
  still reads as text rather than as double-width rubble).

  Ranges may overlap, may arrive in any order, and may run past the end — a range is clipped to the
  text and a range entirely past the end changes nothing. Returns `text` unchanged when `ranges` is
  empty, so the no-entities path costs one list check.
  """
  @spec mask_ranges(binary(), [{non_neg_integer(), non_neg_integer()}], binary()) :: binary()
  def mask_ranges(text, [], _mask) when is_binary(text), do: text

  def mask_ranges(text, ranges, mask)
      when is_binary(text) and is_list(ranges) and is_binary(mask) do
    covered = MapSet.new(Enum.flat_map(ranges, &expand/1))

    {chunks, _position} =
      text
      |> to_codepoints()
      |> Enum.reduce({[], 0}, fn codepoint, {acc, position} ->
        width = units(codepoint)

        chunk =
          if MapSet.member?(covered, position),
            do: mask,
            else: <<codepoint::utf8>>

        {[chunk | acc], position + width}
      end)

    chunks |> Enum.reverse() |> IO.iodata_to_binary()
  end

  def mask_ranges(text, _ranges, _mask), do: text

  # Every UTF-16 position a range covers. A codepoint is masked when its FIRST unit is covered, so a
  # range that ends mid-surrogate (a malformed client span) still masks the whole character rather
  # than emitting half of one.
  defp expand({offset, length})
       when is_integer(offset) and is_integer(length) and offset >= 0 and length > 0 do
    offset..(offset + length - 1)//1
  end

  defp expand(_range), do: []

  defp units(codepoint) when codepoint >= 0x10000, do: 2
  defp units(_codepoint), do: 1

  # String.to_charlist/1 raises on invalid UTF-8; a body that reached the store is valid, but a
  # push preview must never crash the fan-out over an encoding surprise.
  defp to_codepoints(text) do
    String.to_charlist(text)
  rescue
    _ -> []
  end
end
