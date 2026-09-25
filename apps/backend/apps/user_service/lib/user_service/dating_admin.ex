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

  alias SharedInfra.AdminPage
  alias UserService.Repo

  # Server-owned. A caller may ask for less; asking for more (or for a nonsense value) gets this.

  @doc """
  Numbered pages of matches, newest first. attrs: "app_id", optional "q" (a user id or a name
  fragment), "page", "page_size". The total is counted over the same filter.
  """
  def list_matches(attrs) do
    page = AdminPage.parse(attrs)
    base = attrs["app_id"] |> base_query() |> apply_search(attrs["q"])
    paginate(base, page)
  rescue
    _ -> {:ok, Map.put(AdminPage.envelope(AdminPage.parse(attrs), 0), :matches, [])}
  end

  @doc """
  Every match for ONE user, newest first. attrs: "app_id", "user_id", "page", "page_size". Same
  bounded page as the list — a per-user view is not a licence to dump.
  """
  def user_matches(attrs) do
    page = AdminPage.parse(attrs)
    user_id = attrs["user_id"]

    base =
      from([m, _lo, _hi] in base_query(attrs["app_id"]),
        where:
          m.user_low_id == type(^user_id, :binary_id) or
            m.user_high_id == type(^user_id, :binary_id)
      )

    paginate(base, page)
  rescue
    _ -> {:ok, Map.put(AdminPage.envelope(AdminPage.parse(attrs), 0), :matches, [])}
  end

  # --- internals ---------------------------------------------------------------------------------

  defp base_query(app_id) do
    from(m in "dating_matches",
      join: lo in "user_profiles",
      on: lo.user_id == m.user_low_id,
      join: hi in "user_profiles",
      on: hi.user_id == m.user_high_id,
      where: m.app_id == type(^app_id, :binary_id)
    )
  end

  # COUNT over the same filtered query, then one ordered window. `(matched_at DESC, id DESC)` so two
  # rows can never swap between reads.
  defp paginate(base, page) do
    total = Repo.aggregate(base, :count)

    rows =
      from([m, lo, hi] in base,
        order_by: [desc: m.matched_at, desc: m.id],
        limit: ^page.page_size,
        offset: ^page.offset,
        select: %{
          id: type(m.id, :string),
          user_low_id: type(m.user_low_id, :string),
          user_high_id: type(m.user_high_id, :string),
          user_low_name: lo.display_name,
          user_high_name: hi.display_name,
          user_low_username: lo.username,
          user_high_username: hi.username,
          matched_at: m.matched_at
        }
      )
      |> Repo.all()

    {:ok, Map.put(AdminPage.envelope(page, total), :matches, Enum.map(rows, &encode_row/1))}
  end

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

  defp encode_row(row) do
    %{
      id: row.id,
      user_low_id: row.user_low_id,
      user_high_id: row.user_high_id,
      user_low_name: row.user_low_name,
      user_high_name: row.user_high_name,
      user_low_username: row.user_low_username,
      user_high_username: row.user_high_username,
      matched_at: DateTime.to_iso8601(row.matched_at),
      # Always true: an unmatched row is deleted, not flagged. Stated explicitly so a reader of the
      # payload is not left wondering whether the field is missing or the data is.
      active: true
    }
  end
end
