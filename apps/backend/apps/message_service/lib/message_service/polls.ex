defmodule MessageService.Polls do
  @moduledoc """
  Polls (Tier-3) — a poll is a MESSAGE (`message_type: "poll"`) whose definition (question, options with
  server-generated stable ids, allows_multiple) lives in `metadata.poll`; votes live in `poll_votes`
  (one row per message/user/option), and the aggregate is ALWAYS computed from those rows at fetch time —
  the `poll_updated` broadcast is an optimization, never the source of truth (a client that misses it and
  refetches history sees identical results).

  THE AGGREGATE (what clients code against; viewer-INDEPENDENT — voters are public, WhatsApp group
  parity, and explicitly NOT read receipts: no privacy setting composes with poll votes):

      poll: %{question, allows_multiple, options: [%{id, text, count, voter_ids}], total_voters}

  `voter_ids` is CAPPED at #{20} per option (earliest voters first) while `count`/`total_voters` stay
  exact — a 256-member multi-choice poll would otherwise cost ~120 KB per message on a history page.
  The full per-option voter list comes from `list_votes/1` (GET .../poll-votes).

  VOTING is one idempotent verb: the submitted option_id set REPLACES the caller's whole vote set
  (first vote / change / un-vote([]) / multi-toggle are all the same operation; last write wins
  wholesale). Single-choice rejects >1 id. Votes are HISTORY: leavers keep their rows (the membership
  gate — the same one sends use — stops them voting again).
  """

  alias MessageService.MessageStore

  @max_question 300
  @max_option_text 100
  @min_options 2
  @max_options 12
  @voter_ids_cap 20

  def voter_ids_cap, do: @voter_ids_cap

  @doc """
  Validate + normalize a client-supplied poll definition (`metadata.poll` at create). Returns the
  SERVER-REBUILT definition — question, allows_multiple, options with server-generated stable ids
  ("o1".."oN", creation order; stable because polls are never edited) — discarding client extras.
  Errors: :poll_invalid_question | :poll_too_few_options | :poll_too_many_options |
  :poll_invalid_option | :poll_duplicate_option.
  """
  def normalize_definition(raw) when is_map(raw) do
    question = string_field(raw, "question")
    options = list_field(raw, "options")

    cond do
      not valid_text?(question, @max_question) ->
        {:error, :poll_invalid_question}

      not is_list(options) or length(options) < @min_options ->
        {:error, :poll_too_few_options}

      length(options) > @max_options ->
        {:error, :poll_too_many_options}

      not Enum.all?(options, &valid_option?/1) ->
        {:error, :poll_invalid_option}

      duplicated_texts?(options) ->
        {:error, :poll_duplicate_option}

      true ->
        {:ok,
         %{
           "question" => String.trim(question),
           "allows_multiple" => boolean_field(raw, "allows_multiple"),
           "options" =>
             options
             |> Enum.with_index(1)
             |> Enum.map(fn {option, index} ->
               %{"id" => "o#{index}", "text" => option |> option_text() |> String.trim()}
             end)
         }}
    end
  end

  def normalize_definition(_raw), do: {:error, :poll_invalid_question}

  @doc "The zero-vote aggregate for a fresh poll (the create ack carries it — no query needed)."
  def zero_aggregate(%{"question" => question, "allows_multiple" => multiple, "options" => options}) do
    %{
      question: question,
      allows_multiple: multiple,
      options: Enum.map(options, &%{id: &1["id"], text: &1["text"], count: 0, voter_ids: []}),
      total_voters: 0
    }
  end

  @doc """
  Replace the caller's vote set for a poll message → {:ok, %{message_id, poll}} with the fresh
  aggregate. Errors: :message_not_found (unknown / tombstoned / not a poll — nothing revealed),
  :poll_invalid_option (an id not in the definition), :poll_single_choice (>1 id on single-choice).
  """
  def vote(attrs) do
    if persistence_enabled?() do
      with {:ok, conversation_id} <- required(attrs, "conversation_id"),
           {:ok, message_id} <- required(attrs, "message_id"),
           {:ok, user_id} <- required(attrs, "user_id"),
           {:ok, option_ids} <- option_ids(attrs) do
        MessageStore.poll_vote(%{
          "conversation_id" => conversation_id,
          "message_id" => message_id,
          "user_id" => user_id,
          "option_ids" => option_ids
        })
      end
    else
      {:ok, %{message_id: Map.get(attrs, "message_id"), poll: nil}}
    end
  end

  @doc """
  The FULL per-option voter lists for one poll (the "view votes" screen — voter_ids in the aggregate
  are capped). → {:ok, %{message_id, options: [%{id, text, count, voter_ids}], total_voters}}.
  """
  def list_votes(attrs) do
    if persistence_enabled?() do
      with {:ok, conversation_id} <- required(attrs, "conversation_id"),
           {:ok, message_id} <- required(attrs, "message_id") do
        MessageStore.list_poll_votes(%{
          "conversation_id" => conversation_id,
          "message_id" => message_id
        })
      end
    else
      {:ok, %{message_id: Map.get(attrs, "message_id"), options: [], total_voters: 0}}
    end
  end

  @doc """
  Build the aggregate from a definition + votes (`[{option_id, user_id}]` in vote-time order). Pure —
  shared by the Postgres and InMemory adapters so the shape can't drift. `cap` bounds voter_ids per
  option (counts stay exact); `nil` = uncapped (the view-votes screen).
  """
  def build_aggregate(definition, votes, cap \\ @voter_ids_cap) do
    voters_by_option = Enum.group_by(votes, fn {option_id, _u} -> option_id end, fn {_o, u} -> u end)

    %{
      question: definition["question"],
      allows_multiple: definition["allows_multiple"] == true,
      options:
        Enum.map(definition["options"], fn %{"id" => id, "text" => text} ->
          voters = Map.get(voters_by_option, id, [])

          %{
            id: id,
            text: text,
            count: length(voters),
            voter_ids: if(cap, do: Enum.take(voters, cap), else: voters)
          }
        end),
      total_voters: votes |> Enum.map(fn {_o, u} -> u end) |> Enum.uniq() |> length()
    }
  end

  # --- helpers -----------------------------------------------------------------------------------

  # The submitted set, deduped, order preserved. [] is a valid un-vote.
  defp option_ids(attrs) do
    case Map.get(attrs, "option_ids") do
      ids when is_list(ids) ->
        if Enum.all?(ids, &(is_binary(&1) and &1 != "")) do
          {:ok, Enum.uniq(ids)}
        else
          {:error, :poll_invalid_option}
        end

      _ ->
        {:error, :poll_invalid_option}
    end
  end

  defp valid_option?(option) do
    text = option_text(option)
    valid_text?(text, @max_option_text)
  end

  defp option_text(option) when is_map(option),
    do: Map.get(option, "text") || Map.get(option, :text)

  defp option_text(option) when is_binary(option), do: option
  defp option_text(_option), do: nil

  defp duplicated_texts?(options) do
    texts = Enum.map(options, &(&1 |> option_text() |> String.trim() |> String.downcase()))
    length(Enum.uniq(texts)) != length(texts)
  end

  defp valid_text?(value, max),
    do: is_binary(value) and String.trim(value) != "" and String.length(value) <= max

  defp string_field(map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp list_field(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_list(value) -> value
      _ -> nil
    end
  end

  defp boolean_field(map, key), do: SharedInfra.Attrs.get(map, String.to_atom(key)) == true

  defp required(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :message_invalid}
    end
  end

  defp persistence_enabled? do
    Application.get_env(:message_service, :message_persistence, false) ||
      System.get_env("MESSAGE_DB_BACKED") == "true"
  end
end
