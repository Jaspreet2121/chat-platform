# MOVED OUT OF the boundary test (2026-09-18): a second suite needs this fake to drive the SCYLLA
# list path, and a module defined inside a test FILE only exists when that file is in the run — so
# the new suite passed in a full sweep and died alone with "module is not available". Support files
# are always compiled.
defmodule MessageService.TestScyllaClient do
  @moduledoc false

  @behaviour SharedInfra.Scylla.Client

  use Agent

  @name __MODULE__

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> [] end, name: @name)
  end

  def reset do
    ensure_started()
    Agent.update(@name, fn _messages -> [] end)
  end

  @impl true
  def prepare(statement, opts \\ []) do
    {:ok, %{statement: statement, opts: opts}}
  end

  @impl true
  def execute(statement, params, opts \\ []) do
    ensure_started()

    cond do
      String.contains?(statement, "INSERT INTO messages_by_conversation") ->
        Agent.update(@name, fn messages -> [message_from_params(params) | messages] end)
        {:ok, %{statement: statement, params: params, opts: opts}}

      String.contains?(statement, "INSERT INTO message_receipts_by_conversation") ->
        {:ok, %{statement: statement, params: params, opts: opts}}

      String.contains?(statement, "SET body = ?, status = ?, edited_at = ?") ->
        [body, status, edited_at, conversation_id, bucket_date, message_id] = params

        update_message(conversation_id, bucket_date, message_id, %{
          body: body,
          status: status,
          edited_at: edited_at
        })

        {:ok, %{statement: statement, params: params, opts: opts}}

      String.contains?(statement, "SET status = ?, deleted_at = ?") ->
        [status, deleted_at, conversation_id, bucket_date, message_id] = params

        update_message(conversation_id, bucket_date, message_id, %{
          status: status,
          deleted_at: deleted_at
        })

        {:ok, %{statement: statement, params: params, opts: opts}}

      # Point read (the bucket-derived get): WHERE conversation_id = ? AND bucket_date = ? AND message_id = ?
      String.contains?(statement, "AND message_id = ?") ->
        [conversation_id, bucket_date, message_id] = params

        rows =
          @name
          |> Agent.get(& &1)
          |> Enum.filter(
            &(&1.conversation_id == conversation_id and &1.bucket_date == bucket_date and
                &1.message_id == message_id)
          )

        {:ok, %{statement: statement, params: params, opts: opts, rows: rows}}

      # Cursor page within one bucket: WHERE conversation_id = ? AND bucket_date = ? AND message_id < ?
      String.contains?(statement, "AND message_id < ?") ->
        [conversation_id, bucket_date, before_id, limit] = params

        rows =
          @name
          |> Agent.get(& &1)
          |> Enum.filter(
            &(&1.conversation_id == conversation_id and &1.bucket_date == bucket_date and
                timeuuid_before?(&1.message_id, before_id))
          )
          |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
          |> Enum.take(limit)

        {:ok, %{statement: statement, params: params, opts: opts, rows: rows}}

      String.contains?(statement, "FROM messages_by_conversation") ->
        [conversation_id, bucket_date, limit] = params

        rows =
          @name
          |> Agent.get(& &1)
          |> Enum.filter(
            &(&1.conversation_id == conversation_id and &1.bucket_date == bucket_date)
          )
          |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
          |> Enum.take(limit)

        {:ok, %{statement: statement, params: params, opts: opts, rows: rows}}

      true ->
        {:error, :unexpected_statement}
    end
  end

  # POSITIONAL BY NECESSITY — this mirrors MessageTimelineWrites.insert_message_plan/1's parameter
  # ORDER, so the two must change together. A column added to the plan and not here raises
  # FunctionClauseError from inside the Agent, which surfaces as an opaque GenServer exit rather than
  # a readable diff (view_once, 115, cost exactly that). The rows this builds are handed straight back
  # as SELECT results, so a field missing here also silently disappears from every read round-trip.
  defp message_from_params([
         conversation_id,
         bucket_date,
         message_id,
         sender_user_id,
         message_type,
         body,
         media_id,
         reply_to_message_id,
         status,
         metadata,
         view_once,
         created_at,
         edited_at,
         deleted_at
       ]) do
    %{
      conversation_id: conversation_id,
      bucket_date: bucket_date,
      message_id: message_id,
      sender_user_id: sender_user_id,
      message_type: message_type,
      body: body,
      media_id: media_id,
      reply_to_message_id: reply_to_message_id,
      status: status,
      metadata: metadata,
      view_once: view_once,
      created_at: created_at,
      edited_at: edited_at,
      deleted_at: deleted_at
    }
  end

  # CQL orders timeuuids by their EMBEDDED TIMESTAMP, not lexically — the fake must compare the same
  # way or it models an engine that does not exist.
  defp timeuuid_before?(id, before_id) do
    with {:ok, a} <- MessageService.Persistence.ScyllaCodec.timeuuid_to_datetime(id),
         {:ok, b} <- MessageService.Persistence.ScyllaCodec.timeuuid_to_datetime(before_id) do
      DateTime.before?(a, b)
    else
      _ -> false
    end
  end

  defp update_message(conversation_id, bucket_date, message_id, updates) do
    Agent.update(@name, fn messages ->
      Enum.map(messages, fn message ->
        if message.conversation_id == conversation_id and message.bucket_date == bucket_date and
             message.message_id == message_id do
          Map.merge(message, updates)
        else
          message
        end
      end)
    end)
  end

  defp ensure_started do
    case Process.whereis(@name) do
      nil ->
        {:ok, _pid} = start_link()
        :ok

      _pid ->
        :ok
    end
  end
end
