defmodule MessageService.Checklists do
  @moduledoc """
  CHECKLIST messages (126) — a to-do list that IS a message.

  Built on the polls skeleton (`MessageService.Polls`) and deliberately the same in every place the
  two features face the same question:

    * the DEFINITION (`metadata.checklist`) is server-rebuilt at create and immutable — items with
      server-generated stable ids, plus `others_can_check` / `others_can_add`;
    * the MUTABLE state (ticks, added items) lives in `checklist_items`, one row per changed item;
    * the AGGREGATE is ALWAYS recomputed from the definition plus those rows at fetch time. The
      `checklist_updated` broadcast is an optimization, never the source of truth — a client that
      misses it and refetches sees identical state.

  ## `body` is the TITLE

  A checklist's message body is its title, in plain text. That is what makes search, the inbox
  preview and push notifications work with no checklist-awareness anywhere: to every one of those
  surfaces a checklist is a text message. The item texts and the done count are carried ONLY on the
  message payload and the socket frame.

  ## `done_by` is PUBLIC — and is not a read receipt

  Who ticked an item is visible to every member, exactly as poll voters are. This is a deliberate
  product decision recorded here and in the contract: it is a shared list, and "who did this" is the
  point of one. It does NOT compose with the read-receipt privacy setting — that setting governs
  whether you were seen READING, which is a different question from what you chose to DO.

  ## Caps

  30 items per message, 200 characters per item. Both are enforced here AND in the schema (a CHECK
  on the text, a bounded unique position for added items) so no path can store more.
  """

  alias MessageService.MessageStore

  @max_items 30
  @max_item_text 200
  @max_title 300

  def max_items, do: @max_items
  def max_item_text, do: @max_item_text

  @doc """
  Validate + normalize a client-supplied definition (`metadata.checklist` at create). Returns the
  SERVER-REBUILT definition — items with stable ids ("i1".."iN", creation order) and the two
  permission booleans — discarding client extras, exactly as `Polls.normalize_definition/1` does.

  Errors: `:checklist_no_items` | `:checklist_too_many_items` | `:checklist_text_too_long` |
  `:checklist_invalid_item`.
  """
  def normalize_definition(raw) when is_map(raw) do
    with {:ok, items} <- normalize_items(get(raw, "items")) do
      {:ok,
       %{
         "items" => items,
         # Default CLOSED on both: a list the author made is the author's until they say otherwise.
         "others_can_check" => get(raw, "others_can_check") == true,
         "others_can_add" => get(raw, "others_can_add") == true
       }}
    end
  end

  def normalize_definition(_raw), do: {:error, :checklist_no_items}

  defp normalize_items(items) when is_list(items) do
    cond do
      items == [] ->
        {:error, :checklist_no_items}

      length(items) > @max_items ->
        {:error, :checklist_too_many_items}

      true ->
        items
        |> Enum.with_index(1)
        |> Enum.reduce_while({:ok, []}, fn {raw, index}, {:ok, acc} ->
          case item_text(raw) do
            {:ok, text} -> {:cont, {:ok, acc ++ [%{"id" => "i#{index}", "text" => text}]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp normalize_items(_items), do: {:error, :checklist_no_items}

  defp item_text(raw) do
    value =
      cond do
        is_binary(raw) -> raw
        is_map(raw) -> get(raw, "text")
        true -> nil
      end

    cond do
      not is_binary(value) -> {:error, :checklist_invalid_item}
      String.trim(value) == "" -> {:error, :checklist_invalid_item}
      String.length(value) > @max_item_text -> {:error, :checklist_text_too_long}
      true -> {:ok, String.trim(value)}
    end
  end

  @doc "The title (message body) a checklist carries. Same bound as a poll question."
  def valid_title?(title),
    do: is_binary(title) and String.trim(title) != "" and String.length(title) <= @max_title

  @doc """
  The aggregate clients code against — the definition's items in order, then any ADDED items by
  position, each merged with its stored state:

      %{items: [%{id, text, done, done_by, done_at}], done_count: n, total: n}

  PURE, so the Postgres and in-memory adapters cannot drift. `rows` is the stored state, in any
  order; a row with `text` is an added item, a row without is a tick on a definition item.
  """
  def build_aggregate(definition, rows) do
    by_id = Map.new(rows, &{row_id(&1), &1})

    defined =
      definition
      |> Map.get("items", [])
      |> Enum.map(fn item ->
        id = Map.get(item, "id")
        render(id, Map.get(item, "text"), Map.get(by_id, id))
      end)

    added =
      rows
      |> Enum.filter(&(row_text(&1) != nil))
      |> Enum.sort_by(&(row_position(&1) || 0))
      |> Enum.map(fn row -> render(row_id(row), row_text(row), row) end)

    items = defined ++ added

    %{
      items: items,
      done_count: Enum.count(items, & &1.done),
      total: length(items)
    }
  end

  defp render(id, text, nil),
    do: %{id: id, text: text, done: false, done_by: nil, done_at: nil}

  defp render(id, text, row) do
    %{
      id: id,
      text: text,
      done: row_done(row) == true,
      # PUBLIC, by design — see the moduledoc.
      done_by: row_done_by(row),
      done_at: iso8601(row_done_at(row))
    }
  end

  @doc "The zero aggregate for a freshly created checklist (no rows yet) — the create ack's payload."
  def zero_aggregate(definition), do: build_aggregate(definition, [])

  @doc "Tick or untick one item. See `MessageStore.checklist_tick/1` for the concurrency contract."
  def tick(attrs) do
    if persistence_enabled?() do
      with {:ok, conversation_id} <- required(attrs, "conversation_id"),
           {:ok, message_id} <- required(attrs, "message_id"),
           {:ok, item_id} <- required(attrs, "item_id"),
           {:ok, user_id} <- required(attrs, "user_id"),
           {:ok, done} <- required_boolean(attrs, "done") do
        MessageStore.checklist_tick(%{
          "conversation_id" => conversation_id,
          "message_id" => message_id,
          "item_id" => item_id,
          "user_id" => user_id,
          "done" => done,
          # ABSENT and NULL mean different things: absent = "I did not read the item first" (still
          # refused — the contract requires the token), null = "I believe it is not done".
          "if_unchanged_since" => Map.get(attrs, "if_unchanged_since"),
          "if_unchanged_since_given" => given?(attrs, "if_unchanged_since")
        })
      end
    else
      {:ok, %{message_id: Map.get(attrs, "message_id"), checklist: nil}}
    end
  end

  @doc "Append an item. Author, or anyone when `others_can_add`."
  def add_item(attrs) do
    if persistence_enabled?() do
      with {:ok, conversation_id} <- required(attrs, "conversation_id"),
           {:ok, message_id} <- required(attrs, "message_id"),
           {:ok, user_id} <- required(attrs, "user_id"),
           {:ok, text} <- item_text(%{"text" => Map.get(attrs, "text")}) do
        MessageStore.checklist_add_item(%{
          "conversation_id" => conversation_id,
          "message_id" => message_id,
          "user_id" => user_id,
          "text" => text
        })
      end
    else
      {:ok, %{message_id: Map.get(attrs, "message_id"), checklist: nil}}
    end
  end

  @doc """
  May `user_id` tick an item on this checklist? The author always may; everyone else only when
  `others_can_check`. (Conversation membership is the gateway's check and runs first.)
  """
  def may_tick?(definition, author_id, user_id),
    do: user_id == author_id or Map.get(definition, "others_can_check") == true

  @doc "May `user_id` add an item? Author always; everyone else only when `others_can_add`."
  def may_add?(definition, author_id, user_id),
    do: user_id == author_id or Map.get(definition, "others_can_add") == true

  # ---- row accessors (a row is an Ecto schema struct or a plain map, depending on the adapter) ----

  defp row_id(row), do: fetch(row, :item_id)
  defp row_text(row), do: fetch(row, :text)
  defp row_position(row), do: fetch(row, :position)
  defp row_done(row), do: fetch(row, :done)
  defp row_done_by(row), do: to_string_or_nil(fetch(row, :done_by))
  defp row_done_at(row), do: fetch(row, :done_at)

  defp fetch(row, key) when is_map(row),
    do: Map.get(row, key) || Map.get(row, Atom.to_string(key))

  defp fetch(_row, _key), do: nil

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(value), do: to_string(value)

  @doc "ISO-8601 for a stored timestamp; passes a string through (the shape clients compare against)."
  def iso8601(nil), do: nil
  def iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def iso8601(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value) <> "Z"
  def iso8601(value) when is_binary(value), do: value
  def iso8601(_value), do: nil

  # PRESENCE-based, not `Map.get(a) || Map.get(b)`: `done` is boolean-valued, and a legitimate
  # `false` is falsy — the `||` form reads it as "absent" and refuses every untick with
  # :message_invalid. (The recorded trap; `SharedInfra.Attrs.get/2` exists for exactly this.)
  defp get(map, key) when is_map(map) and is_binary(key) do
    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      match?(atom when is_atom(atom) and not is_nil(atom), safe_atom(key)) and
          Map.has_key?(map, safe_atom(key)) ->
        Map.get(map, safe_atom(key))

      true ->
        nil
    end
  end

  defp get(_map, _key), do: nil

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp given?(attrs, key), do: Map.has_key?(attrs, key) or Map.has_key?(attrs, safe_atom(key))

  defp required(attrs, key) do
    case get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :message_invalid}
    end
  end

  defp required_boolean(attrs, key) do
    case get(attrs, key) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, :message_invalid}
    end
  end

  defp persistence_enabled? do
    Application.get_env(:message_service, :message_persistence, false) ||
      System.get_env("MESSAGE_DB_BACKED") in ["true", "1", "yes"]
  end
end
