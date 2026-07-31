defmodule MessageService.ShadowMirror do
  @moduledoc """
  The SHADOW half of dual-write (C7): mirrors committed Postgres message writes into Scylla.
  Postgres stays authoritative; this module is fire-and-forget by design.

  ISOLATION — a shadow failure must never fail or slow the user's write:

    * the mirror runs in a DETACHED task under `MessageService.ShadowMirror.TaskSupervisor`
      (`start_child`, never `async`/`await`) — the request process neither links to nor waits on it,
      so a mirror crash cannot take the request down and a slow mirror adds zero request latency;
    * every Scylla call carries an explicit #{2_000}ms timeout — a hung node bounds the TASK's
      lifetime, not the request's (the request already returned);
    * with the container STOPPED (production's current state) the client returns
      `:scylla_unavailable` from a local process check — near-zero cost per message;
    * a task outliving its request is normal and harmless: it holds no request state, only the
      already-committed row's data, and ends after one bounded attempt (no retries in-task — the
      FAILURE RECORD is the retry mechanism).

  RECORDING — a failed mirror is a ROW, not a log line: `scylla_mirror_failures` (088) captures
  (conversation, message, op, reason); `MessageService.ScyllaBackfill.repair_failures/0` re-reads the
  authority and re-mirrors — the same rebuild-from-authority shape as C4's repair_media_projections.
  Everything mirrored is a keyed upsert, so repair and racing writes are idempotent.

  WEBHOOKS ARE DELIBERATELY NOT MIRRORED: the Postgres adapter already emitted the event in its own
  transaction; the Scylla stage/promote path (C6) belongs to the flip, not the shadow — mirroring it
  would double-deliver.

  In :test the mirror runs INLINE (`:scylla_shadow_async` false — the status-sweep precedent) so
  assertions are deterministic; production is async.
  """

  require Logger

  alias MessageService.Persistence.MediaProjections
  alias MessageService.Persistence.MessageReactions
  alias MessageService.Persistence.MessageReceipts
  alias MessageService.Persistence.MessageTimelineWrites
  alias MessageService.Repo

  @task_supervisor __MODULE__.TaskSupervisor
  @scylla_timeout_ms 2_000

  def task_supervisor, do: @task_supervisor

  # --- dispatch ------------------------------------------------------------------------------------

  def mirror_put(attrs), do: dispatch(:put, attrs)
  def mirror_edit(attrs), do: dispatch(:edit, attrs)
  def mirror_delete(attrs), do: dispatch(:delete, attrs)
  def mirror_receipt(attrs), do: dispatch(:receipt, attrs)
  def mirror_reaction(attrs), do: dispatch(:reaction, attrs)

  defp dispatch(op, attrs) do
    if Application.get_env(:message_service, :scylla_shadow_async, true) do
      Task.Supervisor.start_child(@task_supervisor, fn -> run(op, attrs) end)
    else
      run(op, attrs)
    end

    :ok
  end

  # --- the mirror operations (all keyed upserts — idempotent under races and repair) ----------------

  defp run(:put, attrs) do
    attempt(:put, attrs, fn client ->
      with {:ok, _} <- execute(client, MessageTimelineWrites.insert_message_plan(attrs)) do
        mirror_media_projections(client, attrs)
      end
    end)
  end

  defp run(:edit, attrs) do
    attempt(:edit, attrs, fn client ->
      execute(client, MessageTimelineWrites.mark_edited_plan(attrs))
    end)
  end

  defp run(:delete, attrs) do
    attempt(:delete, attrs, fn client ->
      with {:ok, _} <- execute(client, MessageTimelineWrites.mark_deleted_plan(attrs)) do
        if is_binary(attrs["media_id"]) and attrs["media_id"] != "" do
          execute(client, MediaProjections.upsert_gallery_plan(Map.put(attrs, "deleted", true)))
        else
          {:ok, :done}
        end
      end
    end)
  end

  defp run(:receipt, attrs) do
    attempt(:receipt, attrs, fn client ->
      execute(client, MessageReceipts.upsert_receipt_plan(attrs))
    end)
  end

  defp run(:reaction, attrs) do
    attempt(:reaction, attrs, fn client ->
      case attrs["__reaction_op"] do
        "remove" -> execute(client, MessageReactions.delete_reaction_plan(attrs))
        _ -> execute(client, MessageReactions.upsert_reaction_plan(attrs))
      end
    end)
  end

  defp mirror_media_projections(client, attrs) do
    if is_binary(attrs["media_id"]) and attrs["media_id"] != "" do
      with {:ok, _} <- execute(client, MediaProjections.insert_reference_plan(attrs)) do
        execute(client, MediaProjections.upsert_gallery_plan(Map.put(attrs, "deleted", false)))
      end
    else
      {:ok, :done}
    end
  end

  # --- plumbing ------------------------------------------------------------------------------------

  defp attempt(op, attrs, fun) do
    client =
      Application.get_env(:message_service, :scylla_client_adapter, SharedInfra.Scylla.Client)

    case fun.(client) do
      {:ok, _} -> :ok
      {:error, reason} -> record_failure(op, attrs, reason)
    end
  rescue
    error -> record_failure(op, attrs, error)
  catch
    :exit, reason -> record_failure(op, attrs, {:exit, reason})
  end

  defp execute(client, plan) do
    case client.execute(plan.statement, plan.params, timeout: @scylla_timeout_ms) do
      {:error, reason} -> {:error, reason}
      {:ok, result} -> {:ok, result}
      other -> {:ok, other}
    end
  end

  defp record_failure(op, attrs, reason) do
    Repo.query!(
      "INSERT INTO scylla_mirror_failures (conversation_id, message_id, op, reason) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, $4)",
      [
        attrs["conversation_id"],
        attrs["message_id"],
        to_string(op),
        inspect(reason) |> String.slice(0, 500)
      ]
    )

    :ok
  rescue
    # Recording itself failing must not crash the task loop — log is the last resort.
    error ->
      Logger.error(
        "shadow mirror: failed to RECORD a failure (#{inspect(op)}): #{Exception.message(error)}"
      )

      :ok
  end
end
