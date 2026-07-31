defmodule ConversationService.ConversationTags do
  @moduledoc """
  CONVERSATION TAGS — user-defined lists over the caller's own conversations (WhatsApp "Lists").

  A tag is PRIVATE to its owner and is never visible to another participant. That is structural, not a
  filter applied at read time: `conversation_tag_assignments` carries no user column, so an assignment
  is reachable only through the tag that owns it, and every query here is anchored on
  `owner_user_id`. There is no code path that could return another user's tags.

  CAPS: #{20} tags per user, #{50} characters per name. A conversation may hold SEVERAL tags — that is
  what makes these lists rather than folders — bounded naturally by the tag cap.

  NAMES are unique per owner CASE-INSENSITIVELY (`name_key = lower(name)`, the usernames precedent):
  "Work" and "work" are indistinguishable as chips in a filter row. A case-only rename keeps the same
  key and is therefore free.

  HOW TAGS REACH CLIENTS is split deliberately:
    * tag DEFINITIONS (name/colour/position) come from `list_tags/1` — at most 20 rows, changing rarely;
    * tag ASSIGNMENTS ride the INBOX ROW as `tag_ids` (see Conversations' @inbox_sql).

  That split is what lets a tag change reach the user's other devices through the EXISTING
  conversation_updated/:pref machinery instead of a new event: the gateway's `pref_mutation` recomputes
  the inbox row after the write, and the row already carries `tag_ids`, so the frame carries the new
  state with no refetch. Filtering itself is CLIENT-side — the client holds the inbox and now holds the
  ids, so a filter is a local predicate with no round trip.
  """

  import Ecto.Query, warn: false

  alias ConversationService.Repo

  @tag_limit 20
  @max_name 50
  @max_color 32

  def tag_limit, do: @tag_limit
  def max_name, do: @max_name

  # --- tag CRUD -----------------------------------------------------------------------------------

  @doc """
  Create a tag owned by the caller. Over the cap → `:tag_limit`; duplicate name (case-insensitively)
  → `:tag_name_taken`; blank/oversized name → `:tag_invalid`.
  """
  def create_tag(attrs) do
    with {:ok, owner} <- required(attrs, "owner_user_id"),
         {:ok, name} <- valid_name(attrs),
         {:ok, color} <- valid_color(attrs),
         :ok <- under_tag_limit(owner) do
      app_id = get(attrs, "app_id")

      case Repo.query(
             "INSERT INTO conversation_tags (owner_user_id, app_id, name, name_key, color, position) " <>
               "VALUES ($1::text::uuid, COALESCE($2::text::uuid, " <>
               "'00000000-0000-0000-0000-000000000001'::uuid), $3, $4, $5, " <>
               "COALESCE((SELECT max(position) + 1 FROM conversation_tags WHERE owner_user_id = $1::text::uuid), 0)) " <>
               "RETURNING id::text, name, color, position",
             [owner, app_id, name, name_key(name), color]
           ) do
        {:ok, %{rows: [[id, name, color, position]]}} ->
          {:ok, tag_response(id, name, color, position)}

        {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} ->
          {:error, :tag_name_taken}

        {:error, error} ->
          fault(error, "ConversationTags.create_tag", {:error, :tag_invalid})
      end
    end
  end

  @doc "Every tag the caller owns, in filter-row order. NEVER anyone else's — the query is owner-anchored."
  def list_tags(attrs) do
    with {:ok, owner} <- required(attrs, "owner_user_id") do
      %{rows: rows} =
        Repo.query!(
          "SELECT id::text, name, color, position FROM conversation_tags " <>
            "WHERE owner_user_id = $1::text::uuid ORDER BY position, created_at",
          [owner]
        )

      {:ok,
       %{
         tags: Enum.map(rows, fn [id, name, color, pos] -> tag_response(id, name, color, pos) end)
       }}
    end
  rescue
    Ecto.Query.CastError -> {:error, :tag_invalid}
  end

  @doc """
  Rename / recolour / reorder. Owner-scoped: another user's tag is `:tag_not_found`, never an
  authorization error that would confirm it exists. Assignments key on `tag_id`, so a rename never
  touches them.
  """
  def update_tag(attrs) do
    with {:ok, owner} <- required(attrs, "owner_user_id"),
         {:ok, tag_id} <- required(attrs, "tag_id"),
         {:ok, sets, params} <- update_sets(attrs) do
      case Repo.query(
             "UPDATE conversation_tags SET #{sets}, updated_at = now() " <>
               "WHERE id = $1::text::uuid AND owner_user_id = $2::text::uuid " <>
               "RETURNING id::text, name, color, position",
             [tag_id, owner | params]
           ) do
        {:ok, %{rows: [[id, name, color, position]]}} ->
          {:ok, tag_response(id, name, color, position)}

        {:ok, %{rows: []}} ->
          {:error, :tag_not_found}

        {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} ->
          {:error, :tag_name_taken}

        {:error, error} ->
          fault(error, "ConversationTags.update_tag", {:error, :tag_invalid})
      end
    end
  end

  @doc """
  Delete a tag. Its assignments go with it (FK ON DELETE CASCADE) and NO conversation is touched —
  nothing about the conversation itself changes.
  """
  def delete_tag(attrs) do
    with {:ok, owner} <- required(attrs, "owner_user_id"),
         {:ok, tag_id} <- required(attrs, "tag_id") do
      %{num_rows: n} =
        Repo.query!(
          "DELETE FROM conversation_tags WHERE id = $1::text::uuid AND owner_user_id = $2::text::uuid",
          [tag_id, owner]
        )

      if n > 0, do: {:ok, %{tag_id: tag_id, deleted: true}}, else: {:error, :tag_not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :tag_not_found}
  end

  # --- assignment ---------------------------------------------------------------------------------

  @doc """
  Assign one of the caller's conversations to one of the caller's tags.

  BOTH sides are checked against the caller: the tag must be theirs (else `:tag_not_found`) and they
  must be an ACTIVE participant of the conversation (else `:not_participant`) — so a tag can never be
  used to probe for conversations the caller is not in. Idempotent.
  """
  def assign(attrs), do: set_assignment(attrs, :assign)

  @doc "Remove the assignment. Idempotent — unassigning an untagged conversation succeeds."
  def unassign(attrs), do: set_assignment(attrs, :unassign)

  defp set_assignment(attrs, mode) do
    with {:ok, owner} <- required(attrs, "owner_user_id"),
         {:ok, tag_id} <- required(attrs, "tag_id"),
         {:ok, conversation_id} <- required(attrs, "conversation_id"),
         :ok <- owns_tag(owner, tag_id),
         :ok <- active_participant(owner, conversation_id) do
      case mode do
        :assign ->
          Repo.query!(
            "INSERT INTO conversation_tag_assignments (tag_id, conversation_id) " <>
              "VALUES ($1::text::uuid, $2::text::uuid) ON CONFLICT DO NOTHING",
            [tag_id, conversation_id]
          )

          {:ok, %{tag_id: tag_id, conversation_id: conversation_id, tagged: true}}

        :unassign ->
          Repo.query!(
            "DELETE FROM conversation_tag_assignments " <>
              "WHERE tag_id = $1::text::uuid AND conversation_id = $2::text::uuid",
            [tag_id, conversation_id]
          )

          {:ok, %{tag_id: tag_id, conversation_id: conversation_id, tagged: false}}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :tag_not_found}
  end

  # --- guards -------------------------------------------------------------------------------------

  defp owns_tag(owner, tag_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM conversation_tags WHERE id = $1::text::uuid AND owner_user_id = $2::text::uuid",
        [tag_id, owner]
      )

    if rows == [], do: {:error, :tag_not_found}, else: :ok
  end

  # An ACTIVE membership. A conversation the caller has left cannot gain new tags — but the ones it
  # already had are kept (see the migration): dormant while left, restored on rejoin, exactly as
  # archive/pin behave.
  defp active_participant(owner, conversation_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM conversation_participants " <>
          "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid AND left_at IS NULL",
        [conversation_id, owner]
      )

    if rows == [], do: {:error, :not_participant}, else: :ok
  end

  defp under_tag_limit(owner) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*)::int FROM conversation_tags WHERE owner_user_id = $1::text::uuid",
        [owner]
      )

    if count >= @tag_limit, do: {:error, :tag_limit}, else: :ok
  end

  # --- shapes + validation ------------------------------------------------------------------------

  defp tag_response(id, name, color, position),
    do: %{tag_id: id, name: name, color: color, position: position}

  defp name_key(name), do: String.downcase(name)

  defp valid_name(attrs) do
    case get(attrs, "name") do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed != "" and String.length(trimmed) <= @max_name,
          do: {:ok, trimmed},
          else: {:error, :tag_invalid}

      _ ->
        {:error, :tag_invalid}
    end
  end

  # Opaque to the server — length-checked only, never interpreted.
  defp valid_color(attrs) do
    case get(attrs, "color") do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) and byte_size(value) <= @max_color -> {:ok, value}
      _ -> {:error, :tag_invalid}
    end
  end

  # Build a partial UPDATE from whatever was supplied. $1/$2 are id/owner, so extra params start at $3.
  # Every supplied field is validated ONCE and its NORMALISED value (trimmed name, nil-ed blank colour)
  # is what reaches the query — so an update stores exactly what create would have stored.
  defp update_sets(attrs) do
    with {:ok, fields} <- update_fields(attrs) do
      if fields == [] do
        {:error, :tag_invalid}
      else
        {sets, params, _next} =
          Enum.reduce(fields, {[], [], 3}, fn {column, value}, {sets, params, i} ->
            fragment =
              case column do
                # name and name_key move together — that IS the case-insensitive uniqueness rule.
                "name" -> "name = $#{i}, name_key = lower($#{i})"
                "position" -> "position = $#{i}::int"
                other -> "#{other} = $#{i}"
              end

            {sets ++ [fragment], params ++ [value], i + 1}
          end)

        {:ok, Enum.join(sets, ", "), params}
      end
    end
  end

  defp update_fields(attrs) do
    [{"name", &valid_name/1}, {"color", &valid_color/1}, {"position", &valid_position/1}]
    |> Enum.reduce_while({:ok, []}, fn {column, validator}, {:ok, acc} ->
      if get(attrs, column) == nil do
        {:cont, {:ok, acc}}
      else
        case validator.(attrs) do
          {:ok, value} -> {:cont, {:ok, acc ++ [{column, value}]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
  end

  defp valid_position(attrs) do
    case get(attrs, "position") do
      n when is_integer(n) and n >= 0 -> {:ok, n}
      _ -> {:error, :tag_invalid}
    end
  end

  defp required(attrs, key) do
    case get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :tag_invalid}
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

  # Repo.query/2 RETURNS the error rather than raising, so there is no __STACKTRACE__ to hand over —
  # the current stack is the next best thing, and `context` names the operation either way.
  defp fault(error, context, domain_result) do
    {:current_stacktrace, trace} = Process.info(self(), :current_stacktrace)
    SharedInfra.SqlFault.classify(error, trace, context, domain_result)
  end
end
