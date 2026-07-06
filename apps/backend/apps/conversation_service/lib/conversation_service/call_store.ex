defmodule ConversationService.CallStore do
  @moduledoc """
  Data-access boundary for the `calls` table (Phase-1 LiveKit calling). Owns the call lifecycle:
  create (ringing) → answer / decline / miss / end, plus point lookup + per-user history.

  Lives in conversation_service because it already owns participant/DM relationships (the conversation a
  call belongs to). Persistence-gated (`CONVERSATION_DB_BACKED`) like the rest of this service: with the
  flag OFF (default in-memory topology / unit tests) every function returns `{:error, :call_unavailable}`
  rather than touching a DB that isn't there.

  NOT related to the legacy `call_sessions`/`call_participants` tables (010) — see 066_calls.sql.
  """

  import Ecto.Query

  alias ConversationService.Repo
  alias ConversationService.Schemas.Call

  @doc """
  Create a ringing call. attrs: "caller_id", "callee_id", "type" ('voice'|'video'), optional
  "conversation_id". Generates the id + a unique LiveKit room_name. Returns `{:ok, call}`.
  """
  def create_call(attrs) do
    with :ok <- persistence(),
         {:ok, caller_id} <- required(attrs, "caller_id"),
         {:ok, callee_id} <- required(attrs, "callee_id"),
         {:ok, type} <- required(attrs, "type") do
      id = Ecto.UUID.generate()

      changeset =
        Call.create_changeset(%{
          id: id,
          room_name: "call-" <> id,
          caller_id: caller_id,
          callee_id: callee_id,
          conversation_id: get(attrs, "conversation_id"),
          type: type,
          status: "ringing",
          created_at: DateTime.utc_now()
        })

      case Repo.insert(changeset) do
        {:ok, call} -> {:ok, response(call)}
        {:error, _changeset} -> {:error, :call_invalid}
      end
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  @doc "Caller answered → accepted + answered_at. attrs: \"call_id\"."
  def mark_answered(attrs),
    do: transition(attrs, %{status: "accepted", answered_at: DateTime.utc_now()})

  @doc "Callee rejected → declined. attrs: \"call_id\"."
  def mark_declined(attrs),
    do: transition(attrs, %{status: "declined", ended_at: DateTime.utc_now()})

  @doc "Never answered (timeout / caller cancel while ringing) → missed. attrs: \"call_id\"."
  def mark_missed(attrs),
    do: transition(attrs, %{status: "missed", ended_at: DateTime.utc_now()})

  @doc "Call finished (hang up) → ended. attrs: \"call_id\"."
  def mark_ended(attrs),
    do: transition(attrs, %{status: "ended", ended_at: DateTime.utc_now()})

  @doc "Fetch a single call by id. attrs: \"call_id\". → {:ok, call} | {:error, :call_not_found}."
  def get_call(attrs) do
    with :ok <- persistence(),
         {:ok, call_id} <- required(attrs, "call_id") do
      case Repo.get(Call, call_id) do
        nil -> {:error, :call_not_found}
        %Call{} = call -> {:ok, response(call)}
      end
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  @doc """
  Call history for a user — every call they placed OR received, most recent first. attrs: "user_id",
  optional "limit" (default 50). → {:ok, %{calls: [...]}}.
  """
  def list_calls_for_user(attrs) do
    with :ok <- persistence(),
         {:ok, user_id} <- required(attrs, "user_id") do
      limit = limit(attrs)

      calls =
        Call
        |> where([c], c.caller_id == ^user_id or c.callee_id == ^user_id)
        |> order_by([c], desc: c.created_at)
        |> limit(^limit)
        |> Repo.all()
        |> Enum.map(&response/1)

      {:ok, %{calls: calls}}
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  # A lifecycle transition: fetch the call, apply the status/timestamp patch.
  defp transition(attrs, patch) do
    with :ok <- persistence(),
         {:ok, call_id} <- required(attrs, "call_id") do
      case Repo.get(Call, call_id) do
        nil ->
          {:error, :call_not_found}

        %Call{} = call ->
          call
          |> Call.status_changeset(patch)
          |> Repo.update()
          |> case do
            {:ok, updated} -> {:ok, response(updated)}
            {:error, _changeset} -> {:error, :call_invalid}
          end
      end
    end
  rescue
    _ -> {:error, :call_invalid}
  end

  defp response(%Call{} = call) do
    %{
      id: call.id,
      room_name: call.room_name,
      caller_id: call.caller_id,
      callee_id: call.callee_id,
      conversation_id: call.conversation_id,
      type: call.type,
      status: call.status,
      created_at: iso8601(call.created_at),
      answered_at: iso8601(call.answered_at),
      ended_at: iso8601(call.ended_at)
    }
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp required(attrs, key) do
    case get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :call_invalid}
    end
  end

  defp get(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))

  defp limit(attrs) do
    case get(attrs, "limit") do
      n when is_integer(n) and n > 0 and n <= 200 -> n
      n when is_binary(n) -> String.to_integer(n)
      _ -> 50
    end
  rescue
    _ -> 50
  end

  defp persistence do
    if Application.get_env(:conversation_service, :conversation_persistence, false) ||
         System.get_env("CONVERSATION_DB_BACKED") in ["true", "1", "yes"] do
      :ok
    else
      {:error, :call_unavailable}
    end
  end
end
