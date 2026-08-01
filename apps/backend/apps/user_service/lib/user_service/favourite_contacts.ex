defmodule UserService.FavouriteContacts do
  @moduledoc """
  FAVOURITE CONTACTS (090) — the Calls tab's favourites, server-side. Per-user, ordered, capped at
  #{20}. Owner-scoped everywhere: a favourite is private to its owner, and every query anchors on
  `owner_user_id` — another user's list is structurally unreachable, the tags (085) discipline.

  User lifecycle, by reused precedent: DELETED favourites prune via FK CASCADE
  (broadcast_list_members); SUSPENDED ones are FILTERED AT READ, never pruned (broadcast send);
  BLOCKED ones remain and are redacted at the gateway by ProfilePresenter — blocks never delete
  relationships anywhere in this codebase.

  Propagation is FETCH-ON-OPEN by design (the Calls tab already fetches on open; favourites change
  at human cadence on the device being touched; no real-time consumer exists) — deliberately NOT a
  third pattern beside the inbox row and :pref.
  """

  alias UserService.Repo

  @limit 20

  def limit, do: @limit

  @doc """
  The owner's favourites, ordered, SUSPENDED FILTERED (status must be 'active' — reversible states
  keep their row but disappear from the read until reinstated). Returns bare rows; the gateway
  enriches through ProfilePresenter.
  """
  def list(attrs) do
    with {:ok, owner} <- required(attrs, "owner_user_id") do
      %{rows: rows} =
        Repo.query!(
          "SELECT f.favourite_user_id::text, f.position FROM favourite_contacts f " <>
            "JOIN users_auth u ON u.id = f.favourite_user_id AND u.status = 'active' " <>
            "WHERE f.owner_user_id = $1::text::uuid " <>
            "ORDER BY f.position, f.created_at",
          [owner]
        )

      {:ok, %{favourites: Enum.map(rows, fn [id, pos] -> %{user_id: id, position: pos} end)}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :favourite_invalid}
  end

  @doc """
  Add a favourite (idempotent — re-favouriting keeps the existing row and position). Over the cap →
  `:favourite_limit`; an unknown/cross-tenant target → `:favourite_unknown_user` (the FK answers).
  Self-favouriting is refused — the Calls tab never renders the caller as their own chip.
  """
  def add(attrs) do
    with {:ok, owner} <- required(attrs, "owner_user_id"),
         {:ok, target} <- required(attrs, "favourite_user_id"),
         :ok <- not_self(owner, target),
         :ok <- under_limit(owner),
         :ok <- target_in_tenant(target, get(attrs, "app_id")) do
      Repo.query!(
        "INSERT INTO favourite_contacts (owner_user_id, favourite_user_id, app_id, position) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, " <>
          "COALESCE($3::text::uuid, '00000000-0000-0000-0000-000000000001'::uuid), " <>
          "COALESCE((SELECT max(position) + 1 FROM favourite_contacts WHERE owner_user_id = $1::text::uuid), 0)) " <>
          "ON CONFLICT (owner_user_id, favourite_user_id) DO NOTHING",
        [owner, target, get(attrs, "app_id")]
      )

      {:ok, %{owner_user_id: owner, favourite_user_id: target, favourited: true}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :favourite_invalid}
  end

  @doc "Remove. Idempotent — removing a non-favourite succeeds."
  def remove(attrs) do
    with {:ok, owner} <- required(attrs, "owner_user_id"),
         {:ok, target} <- required(attrs, "favourite_user_id") do
      Repo.query!(
        "DELETE FROM favourite_contacts " <>
          "WHERE owner_user_id = $1::text::uuid AND favourite_user_id = $2::text::uuid",
        [owner, target]
      )

      {:ok, %{owner_user_id: owner, favourite_user_id: target, favourited: false}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :favourite_invalid}
  end

  @doc """
  Reorder: the FULL ordered list of the owner's favourite user ids. Ids not in the list keep their
  rows and sink below the reordered ones (position continues past the list); unknown ids are ignored
  (an id removed on another device must not fail the reorder from this one).
  """
  def reorder(attrs) do
    with {:ok, owner} <- required(attrs, "owner_user_id"),
         {:ok, ids} <- required_id_list(attrs) do
      ids
      |> Enum.with_index()
      |> Enum.each(fn {id, index} ->
        Repo.query!(
          "UPDATE favourite_contacts SET position = $3 " <>
            "WHERE owner_user_id = $1::text::uuid AND favourite_user_id = $2::text::uuid",
          [owner, id, index]
        )
      end)

      # UNLISTED rows SINK below the reordered block (they would otherwise keep stale positions and
      # interleave — the live suite caught exactly that). Their relative order is preserved.
      Repo.query!(
        "UPDATE favourite_contacts f SET position = sub.rn " <>
          "FROM (SELECT favourite_user_id, " <>
          "             $3 + row_number() OVER (ORDER BY position, created_at) - 1 AS rn " <>
          "      FROM favourite_contacts " <>
          "      WHERE owner_user_id = $1::text::uuid " <>
          "        AND NOT (favourite_user_id = ANY($2::text[]::uuid[]))) sub " <>
          "WHERE f.owner_user_id = $1::text::uuid AND f.favourite_user_id = sub.favourite_user_id",
        [owner, ids, length(ids)]
      )

      list(%{"owner_user_id" => owner})
    end
  rescue
    Ecto.Query.CastError -> {:error, :favourite_invalid}
  end

  # --- guards -------------------------------------------------------------------------------------

  defp not_self(owner, owner), do: {:error, :favourite_invalid}
  defp not_self(_owner, _target), do: :ok

  defp under_limit(owner) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*)::int FROM favourite_contacts WHERE owner_user_id = $1::text::uuid",
        [owner]
      )

    if count >= @limit, do: {:error, :favourite_limit}, else: :ok
  end

  # The target must exist IN THE CALLER'S TENANT (048): a cross-tenant or unknown id is the same
  # answer, so a favourite can't probe other tenants' user ids.
  defp target_in_tenant(target, app_id) do
    tenant = app_id || "00000000-0000-0000-0000-000000000001"

    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM users_auth WHERE id = $1::text::uuid AND app_id = $2::text::uuid",
        [target, tenant]
      )

    if rows == [], do: {:error, :favourite_unknown_user}, else: :ok
  end

  defp required_id_list(attrs) do
    case get(attrs, "favourite_user_ids") do
      ids when is_list(ids) ->
        valid = Enum.filter(ids, &(is_binary(&1) and &1 != ""))
        if valid == [], do: {:error, :favourite_invalid}, else: {:ok, Enum.uniq(valid)}

      _ ->
        {:error, :favourite_invalid}
    end
  end

  defp required(attrs, key) do
    case get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :favourite_invalid}
    end
  end

  defp get(attrs, key) when is_map(attrs) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, String.to_existing_atom(key))
    end
  rescue
    ArgumentError -> nil
  end
end
