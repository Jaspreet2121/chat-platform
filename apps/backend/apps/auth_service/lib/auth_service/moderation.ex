defmodule AuthService.Moderation do
  @moduledoc """
  Admin moderation over the (previously dormant) `enforcement_actions`, `user_reports`,
  `moderation_cases`, and `audit_logs` tables, plus `users_auth.status`.

  Every mutation writes an `audit_logs` row — no silent admin actions. User status changes go through
  the validated `Accounts.set_status/2` changeset; the dormant tables are read/written with raw SQL
  (single statements, parameterized) since building Ecto schemas for read-only-ish moderation tables
  isn't worth it. Suspends are reversible (reactivate); ban reuses status `suspended` (permanent — no
  `ends_at`) with `action_type='ban'` in `enforcement_actions` (the auth-block effect is identical
  since `Sessions.active_user/1` rejects any non-active status). All attrs are string-keyed (they
  arrive as JSON over the internal API).
  """

  alias AuthService.Accounts
  alias AuthService.Repo

  # --- User moderation ----------------------------------------------------------------------------

  def suspend_user(attrs), do: enforce(attrs, "suspend", "suspended", attrs["ends_at"])
  def ban_user(attrs), do: enforce(attrs, "ban", "suspended", nil)

  def reactivate_user(attrs) do
    with {:ok, user_id} <- require_attr(attrs, "user_id"),
         {:ok, user} <- Accounts.set_status(user_id, "active") do
      record_enforcement(user_id, "warn", actor(attrs), reason(attrs, "Reactivated"), nil)
      audit(actor(attrs), "user.reactivate", "user", user_id, %{})
      {:ok, %{user_id: user.id, status: user.status}}
    end
  end

  defp enforce(attrs, action_type, status, ends_at) do
    with {:ok, user_id} <- require_attr(attrs, "user_id"),
         {:ok, user} <- Accounts.set_status(user_id, status) do
      reason = reason(attrs, "#{action_type} by admin")
      record_enforcement(user_id, action_type, actor(attrs), reason, ends_at)
      audit(actor(attrs), "user.#{action_type}", "user", user_id, %{"reason" => reason})
      {:ok, %{user_id: user.id, status: user.status}}
    end
  end

  defp record_enforcement(user_id, action_type, action_by, reason, ends_at) do
    Repo.query!(
      "INSERT INTO enforcement_actions (target_user_id, action_type, action_by, reason, ends_at) " <>
        "VALUES ($1, $2, $3, $4, $5::timestamptz)",
      [uuid_param(user_id), action_type, uuid_param(action_by), reason, ends_at]
    )

    :ok
  end

  # --- Reports ------------------------------------------------------------------------------------

  def list_reports(attrs) do
    {where, params} =
      case present(attrs["status"]) do
        nil -> {"", []}
        status -> {"WHERE status = $1", [status]}
      end

    page = page(attrs)
    page_size = 25
    offset = (page - 1) * page_size

    %Postgrex.Result{rows: rows} =
      Repo.query!(
        "SELECT id::text, reporter_user_id::text, reported_user_id::text, conversation_id::text, " <>
          "reported_message_id, reason, details, status, " <>
          "to_char(created_at, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS created_at " <>
          "FROM user_reports #{where} ORDER BY created_at DESC " <>
          "LIMIT #{page_size} OFFSET #{offset}",
        params
      )

    {:ok,
     %{
       page: page,
       page_size: page_size,
       reports:
         Enum.map(rows, fn [
                             id,
                             reporter,
                             reported,
                             conv,
                             msg,
                             reason,
                             details,
                             status,
                             created_at
                           ] ->
           %{
             id: id,
             reporter_user_id: reporter,
             reported_user_id: reported,
             conversation_id: conv,
             reported_message_id: msg,
             reason: reason,
             details: details,
             status: status,
             created_at: created_at
           }
         end)
     }}
  end

  @report_statuses ~w(open reviewing resolved dismissed)

  def update_report(attrs) do
    with {:ok, report_id} <- require_attr(attrs, "report_id"),
         {:ok, status} <- valid_report_status(attrs["status"]) do
      %Postgrex.Result{num_rows: n} =
        Repo.query!(
          "UPDATE user_reports SET status = $1, updated_at = now() WHERE id = $2",
          [status, uuid_param(report_id)]
        )

      if n == 0 do
        {:error, :report_not_found}
      else
        audit(actor(attrs), "report.#{status}", "report", report_id, %{
          "resolution" => present(attrs["resolution"])
        })

        {:ok, %{id: report_id, status: status}}
      end
    end
  rescue
    Postgrex.Error -> {:error, :report_not_found}
  end

  # --- Audit log ----------------------------------------------------------------------------------

  @doc "Public audit writer so the gateway can record cross-service actions (e.g. admin message delete)."
  def write_audit(attrs) do
    audit(
      actor(attrs),
      attrs["action"] || "unknown",
      attrs["target_type"] || "unknown",
      attrs["target_id"],
      attrs["metadata"] || %{}
    )

    {:ok, %{written: true}}
  end

  def list_audit(attrs) do
    page = page(attrs)
    page_size = 50
    offset = (page - 1) * page_size

    %Postgrex.Result{rows: rows} =
      Repo.query!(
        "SELECT actor_user_id::text, action, target_type, target_id, metadata, " <>
          "to_char(created_at, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS created_at " <>
          "FROM audit_logs ORDER BY created_at DESC LIMIT #{page_size} OFFSET #{offset}"
      )

    {:ok,
     %{
       page: page,
       page_size: page_size,
       entries:
         Enum.map(rows, fn [actor, action, target_type, target_id, metadata, created_at] ->
           %{
             actor_user_id: actor,
             action: action,
             target_type: target_type,
             target_id: target_id,
             metadata: metadata,
             created_at: created_at
           }
         end)
     }}
  end

  # --- internals ----------------------------------------------------------------------------------

  defp audit(actor_user_id, action, target_type, target_id, metadata) do
    Repo.query!(
      "INSERT INTO audit_logs (actor_user_id, action, target_type, target_id, metadata) " <>
        "VALUES ($1, $2, $3, $4, $5::jsonb)",
      [uuid_param(actor_user_id), action, target_type, target_id, Jason.encode!(metadata || %{})]
    )

    :ok
  end

  # uuid columns are typed `uuid`; Postgrex needs the 16-byte binary, not the string form.
  defp uuid_param(nil), do: nil

  defp uuid_param(value) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, binary} -> binary
      :error -> value
    end
  end

  defp require_attr(attrs, key) do
    case present(Map.get(attrs, key)) do
      nil -> {:error, :invalid_request}
      value -> {:ok, value}
    end
  end

  defp valid_report_status(status) do
    if status in @report_statuses, do: {:ok, status}, else: {:error, :invalid_request}
  end

  defp actor(attrs), do: present(attrs["actor_user_id"])
  defp reason(attrs, default), do: present(attrs["reason"]) || default

  defp page(attrs) do
    case Map.get(attrs, "page") do
      n when is_integer(n) and n > 0 ->
        n

      n when is_binary(n) ->
        case Integer.parse(n) do
          {p, _} when p > 0 -> p
          _ -> 1
        end

      _ ->
        1
    end
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil
end
