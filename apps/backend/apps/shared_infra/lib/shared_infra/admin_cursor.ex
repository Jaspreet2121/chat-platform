defmodule SharedInfra.AdminCursor do
  @moduledoc """
  Keyset pagination for the admin console's list endpoints — ONE implementation, so every list pages
  the same way and none of them can drift.

  WHY NOT OFFSET. `LIMIT 50 OFFSET 50` asks the database to count past rows that may not be the same
  rows any more. On these lists that is not theoretical: a sign-up, a new report or an audit row
  arriving between page 1 and page 2 shifts every later row down by one, so the reader SKIPS a row
  they were never shown. A moderator paging a report queue missing one report is the failure this
  exists to prevent. It also degrades: OFFSET 10000 reads ten thousand rows to discard them.

  The cursor is `(sort_column, id)` — the id breaks ties so two rows with the same timestamp can
  never both be "the last row of page 1". It is passed back opaquely as "<iso8601>|<uuid>"; callers
  treat it as a token, and anything unparseable is simply treated as no cursor at all (the first
  page) rather than an error, because a stale bookmark should show you a list, not a 400.

  PAGE SIZE IS THE SERVER'S. A caller may ask for a SMALLER page; it can never ask for a bigger one.
  A list endpoint over personal data with a caller-chosen page size is an export endpoint wearing a
  hat, and `clamp/1` is what stops it being one.
  """

  @page_size 50
  @max_page_size 50

  @doc """
  The SQL expression to select as a row's cursor timestamp.

  FULL PRECISION, and that is not a detail. These lists display `created_at` through
  `to_char(..., 'YYYY-MM-DD"T"HH24:MI:SS"Z"')`, which drops microseconds — and a cursor built from
  that truncated string sits STRICTLY BEFORE the row it names. Forward paging survives it; backward
  paging does not, because `> truncated` matches the boundary row itself and serves it twice. Caught
  by the forward-then-back test, which is the only shape that exposes it. Select this as an extra
  trailing column and build the cursor from that, never from the displayed timestamp.
  """
  def key_column(column), do: "#{column}::text"

  @doc "The default page size for every admin list."
  def page_size, do: @page_size

  @doc """
  The page size to actually use. A caller may narrow a page, NEVER widen it — `min/2`, not the
  caller's number. Anything absent or unparseable gets the default.
  """
  def clamp(nil), do: @page_size
  def clamp(n) when is_integer(n) and n > 0, do: min(n, @max_page_size)

  def clamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> min(n, @max_page_size)
      _ -> @page_size
    end
  end

  def clamp(_), do: @page_size

  @doc "Encode a cursor from a row's sort timestamp and id."
  def encode(ts, id) when is_binary(ts) and is_binary(id) and ts != "" and id != "",
    do: ts <> "|" <> id

  def encode(_ts, _id), do: nil

  @doc """
  Decode a cursor. `{:ok, {ts, id}}` or `:none`.

  A malformed cursor is `:none`, not an error: a bookmark from an older shape of this list should
  land the reader on the first page, not on a failure they cannot act on.
  """
  def decode(value) when is_binary(value) and value != "" do
    case String.split(value, "|", parts: 2) do
      [ts, id] when ts != "" and id != "" -> {:ok, {ts, id}}
      _ -> :none
    end
  end

  def decode(_value), do: :none

  @doc "Which way the reader is paging. Anything but an explicit \"prev\" is forward."
  def direction("prev"), do: :prev
  def direction(_), do: :next

  @doc """
  The keyset predicate, as SQL text, for the row AFTER (`:next`) or BEFORE (`:prev`) the cursor.

  `n` is the number of parameters already bound; the predicate uses `$n+1` and `$n+2`. The
  `::text::timestamptz` / `::text::uuid` double cast is deliberate and load-bearing — Postgrex sends
  a bare string parameter as text, and a single `::uuid` cast against it fails at runtime.
  """
  def where(:next, ts_col, id_col, n),
    do: "(#{ts_col}, #{id_col}) < ($#{n + 1}::text::timestamptz, $#{n + 2}::text::uuid)"

  def where(:prev, ts_col, id_col, n),
    do: "(#{ts_col}, #{id_col}) > ($#{n + 1}::text::timestamptz, $#{n + 2}::text::uuid)"

  @doc """
  The ORDER BY matching the predicate. Paging BACKWARDS reads ascending and the rows are flipped
  afterwards by `to_page/5` — reading descending from a "greater than" cursor would return the
  newest rows on the platform rather than the page before this one.
  """
  def order(:next, ts_col, id_col), do: "ORDER BY #{ts_col} DESC, #{id_col} DESC"
  def order(:prev, ts_col, id_col), do: "ORDER BY #{ts_col} ASC, #{id_col} ASC"

  @doc """
  Turn `page_size + 1` fetched rows into a page.

  Fetching one extra row is how "is there a next page?" is answered without a second COUNT query
  over the whole table. `extract` returns `{ts, id}` for a row.

  Returns `%{items, page_size, next_cursor, prev_cursor}` where a nil cursor means "no page that
  way" — which is what the UI disables its buttons on.
  """
  def to_page(rows, direction, had_cursor?, page_size, extract) do
    has_extra? = length(rows) > page_size
    kept = Enum.take(rows, page_size)

    # Backwards pages were READ ascending; flip them so the caller always sees newest-first.
    items = if direction == :prev, do: Enum.reverse(kept), else: kept

    {next_cursor, prev_cursor} =
      case direction do
        :next ->
          # Coming forward, an extra row means there is more ahead. There is a page BEHIND us
          # exactly when we arrived here on a cursor.
          {if(has_extra?, do: cursor_of(List.last(items), extract)),
           if(had_cursor?, do: cursor_of(List.first(items), extract))}

        :prev ->
          # Coming backwards, we KNOW there is a page ahead — we just came from it. An extra row
          # means there is still something behind.
          {cursor_of(List.last(items), extract),
           if(has_extra?, do: cursor_of(List.first(items), extract))}
      end

    %{items: items, page_size: page_size, next_cursor: next_cursor, prev_cursor: prev_cursor}
  end

  defp cursor_of(nil, _extract), do: nil

  defp cursor_of(row, extract) do
    case extract.(row) do
      {ts, id} -> encode(ts, id)
      _ -> nil
    end
  end
end
