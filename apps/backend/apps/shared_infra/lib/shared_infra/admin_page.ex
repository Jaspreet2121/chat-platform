defmodule SharedInfra.AdminPage do
  @moduledoc """
  Numbered pages for the admin console's lists — ONE implementation, so every list pages the same way.

  "Page 3 of 12, 587 rows" needs two things a keyset cursor cannot give: a total, and a way to jump
  to page 9. So these lists page by LIMIT/OFFSET with a COUNT over the same WHERE. The keyset paging
  this replaces (95e60e1) was chosen because a row arriving between two reads shifts an offset page
  by one; that is real, and it is the trade being made here on purpose: an admin-sized table — tens
  of thousands of rows, read by a person, not a sync job — is well inside what a count and an offset
  handle, and a numbered page the operator can name beats a cursor they cannot.

  What is kept from the keyset design is the part that matters more than the paging style: the
  ORDER is `(created_at DESC, id DESC)` — the id breaks ties so two rows with the same timestamp can
  never swap places between two reads, which is the other way an offset list repeats or skips a row.

  PAGE SIZE IS THE SERVER'S. The selector offers 10/20/50/100; a caller may send anything and gets
  `min(n, 100)`. A list over personal data with a caller-chosen page size is an export endpoint
  wearing a hat, and `parse/1` is what stops it being one.
  """

  @sizes [10, 20, 50, 100]
  @default_size 50
  @max_size 100

  @doc "The page sizes the console offers."
  def sizes, do: @sizes

  @doc "The page size used when a caller does not say."
  def default_size, do: @default_size

  @doc """
  Read `"page"` and `"page_size"` from request params into `%{page, page_size, offset}`.

  Absent, junk, zero and negative all land on page 1 / the default size; a size above the ceiling
  lands ON the ceiling, never above it.
  """
  def parse(params) when is_map(params) do
    page = params |> get("page") |> to_int() |> at_least(1)
    page_size = params |> get("page_size") |> to_int() |> clamp_size()
    %{page: page, page_size: page_size, offset: (page - 1) * page_size}
  end

  def parse(_params), do: parse(%{})

  @doc "The ORDER BY every admin list uses: newest first, id as the tiebreak."
  def order(ts_col, id_col), do: "ORDER BY #{ts_col} DESC, #{id_col} DESC"

  @doc "The LIMIT/OFFSET for a parsed page."
  def window(%{page_size: page_size, offset: offset}), do: "LIMIT #{page_size} OFFSET #{offset}"

  @doc """
  The paging envelope for a response: `%{page, page_size, total, total_pages}`. `total_pages` is
  never 0 — an empty list is "page 1 of 1", which is what the UI's "Page N of M" renders sanely.
  """
  def envelope(%{page: page, page_size: page_size}, total) when is_integer(total) do
    %{
      page: page,
      page_size: page_size,
      total: total,
      total_pages: max(div(total + page_size - 1, page_size), 1)
    }
  end

  defp get(params, key), do: Map.get(params, key) || Map.get(params, String.to_atom(key))

  defp to_int(n) when is_integer(n), do: n

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp to_int(_), do: nil

  defp at_least(n, floor) when is_integer(n) and n >= floor, do: n
  defp at_least(_n, floor), do: floor

  defp clamp_size(n) when is_integer(n) and n > 0, do: min(n, @max_size)
  defp clamp_size(_n), do: @default_size
end
