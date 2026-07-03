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

  # --- Roles (IAM Phase 1) ------------------------------------------------------------------------

  @doc """
  Assign `role` to a user. Validates the role, guards the LAST root (the system can never reach zero
  roots), keeps the compat `is_admin` column in sync, and writes an audit row (old → new). Errors:
  `:invalid_role` (bad role), `:user_not_found`, `:last_root` (would demote the final root).

  Concurrency-safe: locks the full root set (`FOR UPDATE`) before counting, so two simultaneous
  demotions serialize instead of both passing the count check and leaving zero roots.
  """
  def set_role(attrs) do
    with {:ok, user_id} <- require_attr(attrs, "user_id"),
         {:ok, new_role} <- validate_role(attrs["role"]) do
      Repo.transaction(fn ->
        # Lock every root row first (stable order) so concurrent demotions can't race to zero roots.
        %Postgrex.Result{rows: root_rows} =
          Repo.query!("SELECT id::text FROM users_auth WHERE role = 'root' FOR UPDATE")

        root_count = length(root_rows)

        case Repo.query!("SELECT role FROM users_auth WHERE id = $1 FOR UPDATE", [uuid_param(user_id)]) do
          %Postgrex.Result{rows: []} ->
            Repo.rollback(:user_not_found)

          %Postgrex.Result{rows: [[old_role]]} ->
            if old_role == "root" and new_role != "root" and root_count <= 1 do
              Repo.rollback(:last_root)
            else
              Repo.query!(
                "UPDATE users_auth SET role = $1, is_admin = $2, updated_at = now() WHERE id = $3",
                [new_role, SharedInfra.IAM.admin?(new_role), uuid_param(user_id)]
              )

              audit(actor(attrs), "user.role_change", "user", user_id, %{
                "old_role" => old_role,
                "new_role" => new_role
              })

              %{user_id: user_id, role: new_role, previous_role: old_role}
            end
        end
      end)
      |> case do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate_role(role) when is_binary(role) do
    if SharedInfra.IAM.valid_role?(role), do: {:ok, role}, else: {:error, :invalid_role}
  end

  defp validate_role(_), do: {:error, :invalid_role}

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

  # --- Rich user detail ---------------------------------------------------------------------------

  @ts "'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'"

  @doc """
  Aggregates a full admin view of one user across the shared Postgres (auth + profile + per-user stats
  + enforcement + report history). Admin-only surface — no privacy gating. Reads several domains'
  tables directly since they all live in one DB (same approach as analytics/moderation).
  """
  def user_detail(attrs) do
    with {:ok, user_id} <- require_attr(attrs, "user_id"),
         {:ok, auth} <- fetch_auth(user_id) do
      {:ok,
       %{
         auth: auth,
         profile: fetch_profile(user_id),
         stats: fetch_stats(user_id),
         enforcement: fetch_enforcement(user_id),
         reports: %{
           against: fetch_reports(user_id, "reported_user_id"),
           by: fetch_reports(user_id, "reporter_user_id")
         }
       }}
    end
  rescue
    Postgrex.Error -> {:error, :user_not_found}
    Ecto.Query.CastError -> {:error, :user_not_found}
  end

  defp fetch_auth(user_id) do
    case Repo.query!(
           "SELECT id::text, phone_number, email, status, is_admin, " <>
             "to_char(created_at, #{@ts}) AS created_at, to_char(updated_at, #{@ts}) AS updated_at " <>
             "FROM users_auth WHERE id = $1",
           [uuid_param(user_id)]
         ) do
      %Postgrex.Result{rows: [[id, phone, email, status, is_admin, created_at, updated_at]]} ->
        {:ok,
         %{
           user_id: id,
           phone_number: phone,
           email: email,
           status: status,
           is_admin: is_admin,
           created_at: created_at,
           updated_at: updated_at
         }}

      _ ->
        {:error, :user_not_found}
    end
  end

  defp fetch_profile(user_id) do
    case Repo.query!(
           "SELECT display_name, avatar_media_id::text, bio, " <>
             "to_char(created_at, #{@ts}) AS created_at, to_char(updated_at, #{@ts}) AS updated_at " <>
             "FROM user_profiles WHERE user_id = $1",
           [uuid_param(user_id)]
         ) do
      %Postgrex.Result{rows: [[display_name, avatar, bio, created_at, updated_at]]} ->
        %{
          display_name: display_name,
          avatar_media_id: avatar,
          bio: bio,
          created_at: created_at,
          updated_at: updated_at
        }

      _ ->
        nil
    end
  end

  defp fetch_stats(user_id) do
    p = [uuid_param(user_id)]

    [[media_count, storage_bytes]] =
      Repo.query!(
        "SELECT count(*), COALESCE(SUM(size_bytes), 0)::bigint FROM media_assets WHERE owner_user_id = $1",
        p
      ).rows

    %{
      conversations:
        scalar("SELECT count(*) FROM conversation_participants WHERE user_id = $1", p),
      # NOTE: no index on messages.sender_user_id — fine at this scale; add one if message volume grows.
      messages_sent: scalar("SELECT count(*) FROM messages WHERE sender_user_id = $1", p),
      media: media_count,
      storage_bytes: storage_bytes,
      last_active_at: last_active(user_id)
    }
  end

  defp last_active(user_id) do
    %Postgrex.Result{rows: [[value]]} =
      Repo.query!(
        "SELECT to_char(GREATEST(m.last_msg, d.last_seen), #{@ts}) FROM " <>
          "(SELECT max(created_at) AS last_msg FROM messages WHERE sender_user_id = $1) m, " <>
          "(SELECT max(last_seen_at) AS last_seen FROM device_sessions WHERE user_id = $1) d",
        [uuid_param(user_id)]
      )

    value
  end

  defp fetch_enforcement(user_id) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        "SELECT action_type, reason, action_by::text, " <>
          "to_char(starts_at, #{@ts}), to_char(ends_at, #{@ts}), to_char(created_at, #{@ts}) " <>
          "FROM enforcement_actions WHERE target_user_id = $1 ORDER BY created_at DESC LIMIT 50",
        [uuid_param(user_id)]
      )

    Enum.map(rows, fn [action_type, reason, action_by, starts_at, ends_at, created_at] ->
      %{
        action_type: action_type,
        reason: reason,
        action_by: action_by,
        starts_at: starts_at,
        ends_at: ends_at,
        created_at: created_at
      }
    end)
  end

  # `column` is a hard-coded constant ("reported_user_id" | "reporter_user_id") — never user input.
  defp fetch_reports(user_id, column) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        "SELECT id::text, reporter_user_id::text, reported_user_id::text, reason, status, " <>
          "to_char(created_at, #{@ts}) " <>
          "FROM user_reports WHERE #{column} = $1 ORDER BY created_at DESC LIMIT 50",
        [uuid_param(user_id)]
      )

    Enum.map(rows, fn [id, reporter, reported, reason, status, created_at] ->
      %{
        id: id,
        reporter_user_id: reporter,
        reported_user_id: reported,
        reason: reason,
        status: status,
        created_at: created_at
      }
    end)
  end

  defp scalar(sql, params) do
    %Postgrex.Result{rows: [[value]]} = Repo.query!(sql, params)
    value || 0
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
