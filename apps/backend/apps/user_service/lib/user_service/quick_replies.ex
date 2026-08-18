defmodule UserService.QuickReplies do
  @moduledoc """
  Per-user, APP-SCOPED custom slash commands (100): `/shortcut` → a saved body (+ optional media).
  Owner-only CRUD + explicit ordering. Rules: shortcut `^[a-z0-9_]{1,25}$` (lowercase, no slash),
  unique per user (DB-enforced), body ≤ 1000, max #{50} per user. RESERVED (built-in) names are
  refused at the GATEWAY (the built-in list is a product surface there); media ownership likewise.
  """

  import Ecto.Query

  alias UserService.Repo
  alias UserService.Schemas.QuickReply

  @shortcut_pattern ~r/^[a-z0-9_]{1,25}$/
  @max_per_user 50

  def max_per_user, do: @max_per_user

  def list(attrs) do
    with :ok <- persistence(), {:ok, user_id} <- required(attrs, "user_id") do
      rows =
        from(q in QuickReply,
          where: q.user_id == ^user_id,
          order_by: [asc: q.position, asc: q.shortcut]
        )
        |> Repo.all()
        |> Enum.map(&response/1)

      {:ok, %{quick_replies: rows}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :quick_reply_invalid}
  end

  def create(attrs) do
    with :ok <- persistence(),
         {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, app_id} <- required(attrs, "app_id"),
         {:ok, shortcut} <- valid_shortcut(Map.get(attrs, "shortcut")),
         {:ok, body} <- valid_body(Map.get(attrs, "body")),
         :ok <- under_limit(user_id) do
      %QuickReply{}
      |> QuickReply.changeset(%{
        app_id: app_id,
        user_id: user_id,
        shortcut: shortcut,
        body: body,
        media_id: presence(Map.get(attrs, "media_id")),
        position: next_position(user_id)
      })
      |> Repo.insert()
      |> case do
        {:ok, row} -> {:ok, response(row)}
        {:error, %Ecto.Changeset{errors: errors}} -> insert_error(errors)
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :quick_reply_invalid}
  end

  def update(attrs) do
    with :ok <- persistence(),
         {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, id} <- required(attrs, "id"),
         %QuickReply{} = row <- Repo.get_by(QuickReply, id: id, user_id: user_id),
         {:ok, changes} <- update_changes(attrs) do
      row
      |> QuickReply.changeset(changes)
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, response(updated)}
        {:error, %Ecto.Changeset{errors: errors}} -> insert_error(errors)
      end
    else
      nil -> {:error, :quick_reply_not_found}
      other -> other
    end
  rescue
    Ecto.Query.CastError -> {:error, :quick_reply_not_found}
  end

  def delete(attrs) do
    with :ok <- persistence(),
         {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, id} <- required(attrs, "id") do
      case Repo.get_by(QuickReply, id: id, user_id: user_id) do
        %QuickReply{} = row ->
          Repo.delete(row)
          {:ok, %{deleted: true, id: id}}

        nil ->
          {:error, :quick_reply_not_found}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :quick_reply_not_found}
  end

  @doc "Reorder: position = index of the id in `ids`. Ids not owned by the caller are ignored."
  def reorder(attrs) do
    with :ok <- persistence(),
         {:ok, user_id} <- required(attrs, "user_id"),
         ids when is_list(ids) <- Map.get(attrs, "ids") do
      ids
      |> Enum.with_index()
      |> Enum.each(fn {id, index} ->
        from(q in QuickReply, where: q.id == ^id and q.user_id == ^user_id)
        |> Repo.update_all(set: [position: index, updated_at: DateTime.utc_now()])
      end)

      list(%{"user_id" => user_id})
    else
      _ -> {:error, :quick_reply_invalid}
    end
  rescue
    Ecto.Query.CastError -> {:error, :quick_reply_invalid}
  end

  # --- internals ---------------------------------------------------------------------------------

  defp update_changes(attrs) do
    with {:ok, shortcut} <- optional_shortcut(attrs),
         {:ok, body} <- optional_body(attrs) do
      changes =
        %{}
        |> maybe_put(:shortcut, shortcut)
        |> maybe_put(:body, body)
        |> then(fn changes ->
          if Map.has_key?(attrs, "media_id"),
            do: Map.put(changes, :media_id, presence(Map.get(attrs, "media_id"))),
            else: changes
        end)

      {:ok, changes}
    end
  end

  defp optional_shortcut(attrs) do
    case Map.get(attrs, "shortcut") do
      nil -> {:ok, nil}
      value -> valid_shortcut(value)
    end
  end

  defp optional_body(attrs) do
    case Map.get(attrs, "body") do
      nil -> {:ok, nil}
      value -> valid_body(value)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp valid_shortcut(value) when is_binary(value) do
    if Regex.match?(@shortcut_pattern, value),
      do: {:ok, value},
      else: {:error, :invalid_shortcut}
  end

  defp valid_shortcut(_), do: {:error, :invalid_shortcut}

  defp valid_body(value) when is_binary(value) and value != "" do
    if String.length(value) <= 1000, do: {:ok, value}, else: {:error, :invalid_body}
  end

  defp valid_body(_), do: {:error, :invalid_body}

  defp under_limit(user_id) do
    count = from(q in QuickReply, where: q.user_id == ^user_id) |> Repo.aggregate(:count)
    if count < @max_per_user, do: :ok, else: {:error, :quick_reply_limit}
  end

  defp next_position(user_id) do
    (from(q in QuickReply, where: q.user_id == ^user_id, select: max(q.position))
     |> Repo.one() || -1) + 1
  end

  defp insert_error(errors) do
    if Keyword.has_key?(errors, :shortcut) and
         match?({_, [constraint: :unique, constraint_name: _]}, errors[:shortcut]),
       do: {:error, :quick_reply_taken},
       else: {:error, :quick_reply_invalid}
  end

  defp response(%QuickReply{} = row) do
    %{
      id: row.id,
      shortcut: row.shortcut,
      body: row.body,
      media_id: row.media_id,
      position: row.position,
      updated_at: row.updated_at && DateTime.to_iso8601(row.updated_at)
    }
  end

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_), do: nil

  defp required(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :quick_reply_invalid}
    end
  end

  defp persistence do
    if Application.get_env(:user_service, :user_profile_persistence, false) ||
         System.get_env("USER_PROFILE_DB_BACKED") in ["true", "1", "yes"] do
      :ok
    else
      {:error, :quick_reply_unavailable}
    end
  end
end
