defmodule ConversationService.BroadcastLists do
  @moduledoc """
  Broadcast lists (081) — a saved recipient set owned by ONE user (the user_blocks structural
  precedent: user-owned rows, per-tenant, 4-layer client CRUD). NOT a conversation: sending is pure
  gateway orchestration fanning out N independent DMs through the normal create paths; this module is
  only the list storage.

  Caps: #{256} members per list, #{32} lists per user (enforced here, limits carried in the error).
  Members must be same-tenant ACTIVE users at ADD time (a cross-tenant id → :invalid_member — no
  cross-tenant DMs). Lifecycle: HARD-deleted members prune via FK cascade; SUSPENDED members stay on
  the list (reversible) and are FILTERED at send time (`sendable_member_ids` — the same active-only
  filter every discovery path uses).
  """

  alias ConversationService.Repo

  @member_limit 256
  @list_limit 32
  @max_name 100

  def member_limit, do: @member_limit
  def list_limit, do: @list_limit

  @doc "Create a list (name + members). → {:ok, %{list_id, name, member_count}}"
  def create_list(attrs) do
    with {:ok, owner} <- required(attrs, "owner_user_id"),
         {:ok, name} <- valid_name(attrs),
         {:ok, member_ids} <- member_ids(attrs, owner),
         :ok <- ensure_persistence(),
         :ok <- ensure_list_budget(owner),
         app_id = SharedInfra.Tenancy.app_id_or_default(get_attr(attrs, "app_id")),
         :ok <- ensure_members_valid(member_ids, app_id) do
      list_id = Ecto.UUID.generate()

      {:ok, _} =
        Repo.transaction(fn ->
          Repo.query!(
            "INSERT INTO broadcast_lists (id, owner_user_id, app_id, name) " <>
              "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, $4)",
            [list_id, owner, app_id, name]
          )

          insert_members(list_id, member_ids)
        end)

      {:ok, %{list_id: list_id, name: name, member_count: length(member_ids)}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :invalid_request}
  end

  @doc "The owner's lists, newest first. → {:ok, %{lists: [%{list_id, name, member_count, created_at}]}}"
  def list_lists(attrs) do
    with {:ok, owner} <- required(attrs, "owner_user_id"),
         :ok <- ensure_persistence() do
      %{rows: rows} =
        Repo.query!(
          "SELECT l.id::text, l.name, to_char(l.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"'), " <>
            "(SELECT count(*)::int FROM broadcast_list_members m WHERE m.list_id = l.id) " <>
            "FROM broadcast_lists l WHERE l.owner_user_id = $1::text::uuid ORDER BY l.created_at DESC",
          [owner]
        )

      lists =
        Enum.map(rows, fn [id, name, created_at, count] ->
          %{list_id: id, name: name, created_at: created_at, member_count: count}
        end)

      {:ok, %{lists: lists}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :invalid_request}
  end

  @doc """
  One list WITH member ids — the send path's read (and the detail screen). OWNER-scoped: a foreign or
  unknown list is :list_not_found (no existence leak). `sendable_member_ids` is the send-time filter:
  members whose account is still ACTIVE (suspended filtered here; deleted already pruned by cascade).
  """
  def get_list(attrs) do
    with {:ok, owner} <- required(attrs, "owner_user_id"),
         {:ok, list_id} <- required(attrs, "list_id"),
         :ok <- ensure_persistence(),
         {:ok, list} <- fetch_owned(list_id, owner) do
      %{rows: member_rows} =
        Repo.query!(
          "SELECT m.user_id::text, (u.status = 'active') FROM broadcast_list_members m " <>
            "JOIN users_auth u ON u.id = m.user_id WHERE m.list_id = $1::text::uuid ORDER BY m.added_at",
          [list_id]
        )

      {:ok,
       %{
         list_id: list_id,
         name: list.name,
         member_ids: Enum.map(member_rows, fn [id, _active] -> id end),
         sendable_member_ids: for([id, true] <- member_rows, do: id)
       }}
    end
  rescue
    Ecto.Query.CastError -> {:error, :list_not_found}
  end

  @doc "Rename and/or REPLACE the member set (absent members key = keep). → {:ok, %{list_id, name, member_count}}"
  def update_list(attrs) do
    with {:ok, owner} <- required(attrs, "owner_user_id"),
         {:ok, list_id} <- required(attrs, "list_id"),
         :ok <- ensure_persistence(),
         {:ok, list} <- fetch_owned(list_id, owner),
         {:ok, name} <- optional_name(attrs, list.name),
         {:ok, member_ids} <- optional_member_ids(attrs, owner),
         :ok <- if(member_ids, do: ensure_members_valid(member_ids, list.app_id), else: :ok) do
      {:ok, _} =
        Repo.transaction(fn ->
          Repo.query!(
            "UPDATE broadcast_lists SET name = $2, updated_at = now() WHERE id = $1::text::uuid",
            [list_id, name]
          )

          if member_ids do
            Repo.query!("DELETE FROM broadcast_list_members WHERE list_id = $1::text::uuid", [
              list_id
            ])

            insert_members(list_id, member_ids)
          end
        end)

      count = if member_ids, do: length(member_ids), else: member_count(list_id)
      {:ok, %{list_id: list_id, name: name, member_count: count}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :list_not_found}
  end

  defp optional_name(attrs, current) do
    case get_attr(attrs, "name") do
      nil -> {:ok, current}
      _ -> valid_name(attrs)
    end
  end

  defp member_count(list_id) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*)::int FROM broadcast_list_members WHERE list_id = $1::text::uuid",
        [list_id]
      )

    n
  end

  @doc "Delete a list (members cascade). Owner-scoped; idempotent-ish: unknown/foreign → :list_not_found."
  def delete_list(attrs) do
    with {:ok, owner} <- required(attrs, "owner_user_id"),
         {:ok, list_id} <- required(attrs, "list_id"),
         :ok <- ensure_persistence(),
         {:ok, _list} <- fetch_owned(list_id, owner) do
      Repo.query!("DELETE FROM broadcast_lists WHERE id = $1::text::uuid", [list_id])
      {:ok, %{deleted: true}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :list_not_found}
  end

  # --- internals ---------------------------------------------------------------------------------

  defp fetch_owned(list_id, owner) do
    %{rows: rows} =
      Repo.query!(
        "SELECT name, app_id::text FROM broadcast_lists WHERE id = $1::text::uuid AND owner_user_id = $2::text::uuid",
        [list_id, owner]
      )

    case rows do
      [[name, app_id]] -> {:ok, %{name: name, app_id: app_id}}
      _ -> {:error, :list_not_found}
    end
  end

  defp insert_members(_list_id, []), do: :ok

  defp insert_members(list_id, member_ids) do
    Repo.query!(
      "INSERT INTO broadcast_list_members (list_id, user_id) " <>
        "SELECT $1::text::uuid, unnest($2::text[]::uuid[])",
      [list_id, member_ids]
    )

    :ok
  end

  # The validated member set for CREATE (required, deduped, owner excluded — you can't broadcast to
  # yourself; the single-DM path 409s the same intent).
  defp member_ids(attrs, owner) do
    case get_attr(attrs, "member_user_ids") do
      ids when is_list(ids) -> normalize_members(ids, owner)
      _ -> {:error, :invalid_request}
    end
  end

  # For UPDATE: absent = keep current members (nil), present = full replace.
  defp optional_member_ids(attrs, owner) do
    case get_attr(attrs, "member_user_ids") do
      nil -> {:ok, nil}
      ids when is_list(ids) -> normalize_members(ids, owner)
      _ -> {:error, :invalid_request}
    end
  end

  defp normalize_members(ids, owner) do
    ids = ids |> Enum.uniq() |> Enum.reject(&(&1 == owner))

    cond do
      not Enum.all?(ids, &(is_binary(&1) and &1 != "")) -> {:error, :invalid_member}
      length(ids) > @member_limit -> {:error, :member_limit}
      true -> {:ok, ids}
    end
  end

  # Every member must be a same-tenant ACTIVE account at add time (cross-tenant → no DM possible;
  # a dead id would fail the FK anyway — this returns a clean code instead of a 500).
  defp ensure_members_valid([], _app_id), do: :ok

  defp ensure_members_valid(member_ids, app_id) do
    %{rows: [[valid_count]]} =
      Repo.query!(
        "SELECT count(*)::int FROM users_auth WHERE id = ANY($1::text[]::uuid[]) " <>
          "AND app_id = $2::text::uuid AND status = 'active'",
        [member_ids, app_id]
      )

    if valid_count == length(member_ids), do: :ok, else: {:error, :invalid_member}
  end

  defp ensure_list_budget(owner) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*)::int FROM broadcast_lists WHERE owner_user_id = $1::text::uuid",
        [owner]
      )

    if count >= @list_limit, do: {:error, :list_limit}, else: :ok
  end

  defp valid_name(attrs) do
    case get_attr(attrs, "name") do
      name when is_binary(name) ->
        trimmed = String.trim(name)

        if trimmed != "" and String.length(trimmed) <= @max_name,
          do: {:ok, trimmed},
          else: {:error, :invalid_name}

      _ ->
        {:error, :invalid_name}
    end
  end

  defp ensure_persistence do
    if Application.get_env(:conversation_service, :conversation_persistence, false) ||
         System.get_env("CONVERSATION_DB_BACKED") in ["true", "1", "yes"] do
      :ok
    else
      {:error, :conversation_unavailable}
    end
  end

  defp required(attrs, key) do
    case get_attr(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_request}
    end
  end

  defp get_attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))
end
