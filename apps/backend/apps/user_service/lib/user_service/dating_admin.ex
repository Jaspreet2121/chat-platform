defmodule UserService.DatingAdmin do
  @moduledoc """
  ADMIN reads of dating match history (Matches console surface, `users.sensitive.view`).

  READ-ONLY, and deliberately narrow. This module can answer "who matched with whom, and when" and
  nothing else: no swipes, no preferences, no photos, and — categorically — **no location**. Nearby
  presence rows carry a live latitude/longitude and are not exposed here or anywhere in the admin
  API, by decision.

  ## `unmatched` is not a state this can show

  `Dating.unmatch/1` DELETES the `dating_matches` row (and the pair's swipes) rather than flagging
  it, so the table holds live matches only. Everything returned here is therefore active by
  construction; a match that was undone leaves no trace to list. Recording unmatches would be a
  schema change and a product decision about retaining something a user chose to end, which this
  does not make on its own.

  ## Paging is bounded by the SERVER

  The page size is clamped here, not negotiated: an admin surface over personal data must not have a
  "give me everything" shape, and a limit the caller chooses is exactly that. There is deliberately
  no export endpoint.
  """

  import Ecto.Query

  alias UserService.Repo

  # Server-owned. A caller may ask for less; asking for more (or for a nonsense value) gets this.
  @page_size 50
  @max_page_size 50

  @doc "The fixed page size. Exposed so the contract can be asserted rather than described."
  def page_size, do: @page_size

  @doc """
  One page of match history, newest first. attrs: "app_id", optional "q" (a user id or a display-name
  fragment), optional "cursor" (`"<matched_at ISO>|<id>"`), optional "limit".

  Keyset paging on `(matched_at, id)` — a stable order under inserts, unlike OFFSET, which
  re-shuffles a list somebody is paging through while new matches land.
  """
  def list_matches(attrs) do
    limit = clamp_limit(attrs["limit"])
    app_id = attrs["app_id"]

    query =
      from(m in "dating_matches",
        join: lo in "user_profiles",
        on: lo.user_id == m.user_low_id,
        join: hi in "user_profiles",
        on: hi.user_id == m.user_high_id,
        where: m.app_id == type(^app_id, :binary_id),
        order_by: [desc: m.matched_at, desc: m.id],
        limit: ^(limit + 1),
        select: %{
          id: type(m.id, :string),
          user_low_id: type(m.user_low_id, :string),
          user_high_id: type(m.user_high_id, :string),
          user_low_name: lo.display_name,
          user_high_name: hi.display_name,
          matched_at: m.matched_at
        }
      )

    query
    |> apply_search(attrs["q"])
    |> apply_cursor(attrs["cursor"])
    |> Repo.all()
    |> to_page(limit)
  rescue
    _ -> {:ok, %{matches: [], next_cursor: nil, page_size: @page_size}}
  end

  @doc """
  Every match for ONE user, newest first. attrs: "app_id", "user_id", optional "cursor"/"limit".
  Same bounded page as the list — a per-user view is not a licence to dump.
  """
  def user_matches(attrs) do
    limit = clamp_limit(attrs["limit"])
    app_id = attrs["app_id"]
    user_id = attrs["user_id"]

    from(m in "dating_matches",
      join: lo in "user_profiles",
      on: lo.user_id == m.user_low_id,
      join: hi in "user_profiles",
      on: hi.user_id == m.user_high_id,
      where:
        m.app_id == type(^app_id, :binary_id) and
          (m.user_low_id == type(^user_id, :binary_id) or
             m.user_high_id == type(^user_id, :binary_id)),
      order_by: [desc: m.matched_at, desc: m.id],
      limit: ^(limit + 1),
      select: %{
        id: type(m.id, :string),
        user_low_id: type(m.user_low_id, :string),
        user_high_id: type(m.user_high_id, :string),
        user_low_name: lo.display_name,
        user_high_name: hi.display_name,
        matched_at: m.matched_at
      }
    )
    |> apply_cursor(attrs["cursor"])
    |> Repo.all()
    |> to_page(limit)
  rescue
    _ -> {:ok, %{matches: [], next_cursor: nil, page_size: @page_size}}
  end

  # --- internals ---------------------------------------------------------------------------------

  # THE CLAMP. A caller may narrow the page; it may never widen it. Absent, junk, zero, negative and
  # 10_000 all land on the server's own size.
  defp clamp_limit(value) do
    case parse_int(value) do
      n when is_integer(n) and n > 0 -> min(n, @max_page_size)
      _ -> @page_size
    end
  end

  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(_), do: nil

  defp apply_search(query, q) when is_binary(q) and q != "" do
    like = "%#{q}%"

    case Ecto.UUID.cast(q) do
      {:ok, id} ->
        from([m, _lo, _hi] in query,
          where: m.user_low_id == type(^id, :binary_id) or m.user_high_id == type(^id, :binary_id)
        )

      :error ->
        from([_m, lo, hi] in query,
          where: ilike(lo.display_name, ^like) or ilike(hi.display_name, ^like)
        )
    end
  end

  defp apply_search(query, _q), do: query

  # `"<matched_at ISO>|<id>"` — the (matched_at, id) pair the ordering uses, so a row inserted
  # mid-page cannot make the reader skip or repeat one.
  defp apply_cursor(query, cursor) when is_binary(cursor) and cursor != "" do
    with [at, id] <- String.split(cursor, "|", parts: 2),
         {:ok, matched_at, _} <- DateTime.from_iso8601(at),
         {:ok, _} <- Ecto.UUID.cast(id) do
      from([m, _lo, _hi] in query,
        where:
          m.matched_at < type(^matched_at, :utc_datetime_usec) or
            (m.matched_at == type(^matched_at, :utc_datetime_usec) and
               m.id < type(^id, :binary_id))
      )
    else
      _ -> query
    end
  end

  defp apply_cursor(query, _cursor), do: query

  # One extra row is fetched to learn whether there IS a next page, then dropped — so `next_cursor`
  # is null on the last page instead of pointing at nothing.
  defp to_page(rows, limit) do
    {page, rest} = Enum.split(rows, limit)

    next =
      case rest do
        [] -> nil
        _ -> page |> List.last() |> cursor_of()
      end

    {:ok,
     %{
       matches: Enum.map(page, &encode_row/1),
       next_cursor: next,
       page_size: limit
     }}
  end

  defp cursor_of(nil), do: nil
  defp cursor_of(row), do: "#{DateTime.to_iso8601(row.matched_at)}|#{row.id}"

  defp encode_row(row) do
    %{
      id: row.id,
      user_low_id: row.user_low_id,
      user_high_id: row.user_high_id,
      user_low_name: row.user_low_name,
      user_high_name: row.user_high_name,
      matched_at: DateTime.to_iso8601(row.matched_at),
      # Always true: an unmatched row is deleted, not flagged. Stated explicitly so a reader of the
      # payload is not left wondering whether the field is missing or the data is.
      active: true
    }
  end
end
