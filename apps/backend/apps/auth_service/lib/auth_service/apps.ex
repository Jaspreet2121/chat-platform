defmodule AuthService.Apps do
  @moduledoc """
  Self-serve integrator apps (WhatsApp-Business-style). A first-party user registers a business "app"
  and becomes its owner; app-scoped actions are then authorized against `app_owners`. Each registered
  app is a DISTINCT live app_id — the existing app_id seal (V1Auth / realtime / webhook registration)
  isolates integrators for free, and the test-twin allocator (`AuthService.ApiKeys`) derives a per-app
  twin off whichever live app_id it's handed.

  Raw SQL over `AuthService.Repo` (uuid params via the `::text::uuid` cast), mirroring the twin
  allocator — there is no Ecto schema for `apps`. Ownership is recorded ONLY for live apps a user
  creates; twins are never owned directly.
  """

  alias AuthService.Repo

  @doc """
  Register a new LIVE app owned by `owner_user_id`. Allocates a fresh app row (mode='live',
  parent_app_id=NULL) and records the caller as its owner, atomically. Returns %{app_id, name, mode}.
  """
  def create_app(attrs) do
    with {:ok, owner_user_id} <- fetch(attrs, "owner_user_id"),
         {:ok, name} <- fetch(attrs, "name") do
      slug = slugify(name)

      Repo.transaction(fn ->
        with {:ok, %{rows: [[app_id]]}} <-
               Repo.query(
                 "INSERT INTO apps (id, name, slug, mode, parent_app_id) " <>
                   "VALUES (gen_random_uuid(), $1, $2, 'live', NULL) RETURNING id::text",
                 [name, slug]
               ),
             {:ok, _} <-
               Repo.query(
                 "INSERT INTO app_owners (app_id, owner_user_id, role) " <>
                   "VALUES ($1::text::uuid, $2::text::uuid, 'owner')",
                 [app_id, owner_user_id]
               ) do
          %{app_id: app_id, name: name, mode: "live"}
        else
          _ -> Repo.rollback(:app_invalid)
        end
      end)
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, _} -> {:error, :app_invalid}
      end
    end
  end

  @doc "List the LIVE apps `owner_user_id` owns (newest first). Twins are never listed (never owned)."
  def list_apps(attrs) do
    with {:ok, owner_user_id} <- fetch(attrs, "owner_user_id") do
      case Repo.query(
             "SELECT a.id::text, a.name, a.mode, a.created_at::text " <>
               "FROM apps a JOIN app_owners o ON o.app_id = a.id " <>
               "WHERE o.owner_user_id = $1::text::uuid ORDER BY a.created_at DESC",
             [owner_user_id]
           ) do
        {:ok, %{rows: rows}} ->
          {:ok,
           %{
             apps:
               Enum.map(rows, fn [id, name, mode, created_at] ->
                 %{app_id: id, name: name, mode: mode, created_at: created_at}
               end)
           }}

        _ ->
          {:error, :app_invalid}
      end
    end
  rescue
    _ -> {:error, :app_invalid}
  end

  @doc """
  Authorize that `owner_user_id` owns `app_id`. {:ok, %{app_id}} if owned, else {:error, :forbidden}.
  The single gate every app-scoped action runs before acting AS an app_id.
  """
  def owns_app(attrs) do
    with {:ok, owner_user_id} <- fetch(attrs, "owner_user_id"),
         {:ok, app_id} <- fetch(attrs, "app_id") do
      case Repo.query(
             "SELECT 1 FROM app_owners WHERE app_id = $1::text::uuid AND owner_user_id = $2::text::uuid LIMIT 1",
             [app_id, owner_user_id]
           ) do
        {:ok, %{rows: [[_]]}} -> {:ok, %{app_id: app_id}}
        _ -> {:error, :forbidden}
      end
    end
  rescue
    # Malformed uuid etc → treat as not-owned (never leak that an app exists in another owner's account).
    _ -> {:error, :forbidden}
  end

  # --- internals -------------------------------------------------------------------------------

  # Non-secret internal slug; name-derived prefix + random suffix so it never collides (slug is UNIQUE).
  defp slugify(name) do
    prefix =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)

    prefix = if prefix == "", do: "app", else: prefix
    prefix <> "-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
  end

  @doc """
  Owner-facing ENTITY COUNTS for ONE app: `%{users, conversations, messages, storage_bytes}`.

  Every number is a real query — nothing is estimated. `app_id` is mandatory and is the tenant boundary.

  MESSAGES are counted via the PARENT CONVERSATION (`JOIN conversations c ON c.id = m.conversation_id
  WHERE c.app_id`), never `messages.app_id`. `messages.app_id` is stamped from the conversation on write
  today, but rows written before that stamp landed carry the tenant-zero default — the conversation is the
  authoritative tenant of a message either way, so the join is correct for ALL rows, old and new.

  NOTE: counts only. No message content is read, and nothing here is cross-tenant.
  """
  def app_usage(attrs) do
    with {:ok, app_id} <- fetch(attrs, "app_id") do
      {:ok,
       %{
         app_id: app_id,
         users: scalar("SELECT count(*) FROM users_auth WHERE app_id = $1::text::uuid", app_id),
         conversations:
           scalar("SELECT count(*) FROM conversations WHERE app_id = $1::text::uuid", app_id),
         messages:
           scalar(
             "SELECT count(*) FROM messages m JOIN conversations c ON c.id = m.conversation_id " <>
               "WHERE c.app_id = $1::text::uuid",
             app_id
           ),
         storage_bytes:
           scalar(
             "SELECT COALESCE(SUM(size_bytes), 0)::bigint FROM media_assets WHERE app_id = $1::text::uuid",
             app_id
           )
       }}
    end
  rescue
    Ecto.Query.CastError -> {:error, :app_invalid}
    Postgrex.Error -> {:error, :app_invalid}
  end

  @doc """
  PERIOD usage for ONE app — the billing meter (Phase 1: measurement only). For a calendar month (UTC,
  `period` = "YYYY-MM"; start inclusive, next-month-start exclusive):

    * `messages_sent` — messages created in the period, counted via the PARENT CONVERSATION (the same
      tenancy rule as `app_usage/1`: `messages.app_id` is not trusted).
    * `active_users_by_messages` — DISTINCT senders in the period. Named honestly: this is sender-MAU
      (users_auth has no activity timestamp, and Phase 1 adds no hot-path writes), so lurkers who only
      read are NOT counted. Conservative by construction.
    * `call_seconds` — SUM(ended_at - answered_at) over ANSWERED calls, attributed to the month of
      `answered_at` (a call spanning the boundary bills entirely to the month it was answered in — one
      simple, disputable-proof rule). Missed/declined (never answered) and still-ongoing calls (no
      ended_at yet) contribute zero. Calls carry no app_id — tenancy via the CALLER's users_auth row
      (both parties are always the same app; the established call_identities rule). Seconds, not
      minutes: minutes are presentation.
    * `storage_bytes_snapshot` — the CURRENT storage total (storage is a stock, not a period flow;
      the name says snapshot so nobody bills it as one).

  TEST-TWIN EXCLUSION is by construction, not by predicate: 054's design isolates test mode BY app_id
  (a test key resolves to the twin's own app_id), so measuring a live app_id can never include sk_test
  rows — messages, senders, calls, and media under a test key all carry the twin's app_id.

  The measured window is echoed back (`period_start`/`period_end`) so a consumer knows exactly what was
  metered. A malformed or not-yet-started period → `{:error, :invalid_period}`. A period before the app
  existed simply measures zeros.

  READ-ONLY. No plans, no limits, no enforcement here (Phases 2/3).
  """
  def app_usage_period(attrs) do
    with {:ok, app_id} <- fetch(attrs, "app_id"),
         {:ok, period} <- fetch(attrs, "period"),
         {:ok, period_start, period_end} <- parse_period(period) do
      {:ok,
       %{
         app_id: app_id,
         period: period,
         period_start: DateTime.to_iso8601(period_start),
         period_end: DateTime.to_iso8601(period_end),
         messages_sent:
           period_scalar(
             "SELECT count(*) FROM messages m JOIN conversations c ON c.id = m.conversation_id " <>
               "WHERE c.app_id = $1::text::uuid AND m.created_at >= $2 AND m.created_at < $3",
             app_id,
             period_start,
             period_end
           ),
         active_users_by_messages:
           period_scalar(
             "SELECT count(DISTINCT m.sender_user_id) FROM messages m " <>
               "JOIN conversations c ON c.id = m.conversation_id " <>
               "WHERE c.app_id = $1::text::uuid AND m.created_at >= $2 AND m.created_at < $3",
             app_id,
             period_start,
             period_end
           ),
         call_seconds:
           period_scalar(
             "SELECT COALESCE(SUM(EXTRACT(EPOCH FROM (cl.ended_at - cl.answered_at)))::bigint, 0) " <>
               "FROM calls cl JOIN users_auth u ON u.id = cl.caller_id " <>
               "WHERE u.app_id = $1::text::uuid AND cl.answered_at >= $2 AND cl.answered_at < $3 " <>
               "AND cl.ended_at IS NOT NULL",
             app_id,
             period_start,
             period_end
           ),
         storage_bytes_snapshot:
           scalar(
             "SELECT COALESCE(SUM(size_bytes), 0)::bigint FROM media_assets WHERE app_id = $1::text::uuid",
             app_id
           )
       }}
    end
  rescue
    Ecto.Query.CastError -> {:error, :app_invalid}
    Postgrex.Error -> {:error, :app_invalid}
  end

  # "YYYY-MM" → {start_of_month, start_of_next_month} in UTC. The CURRENT (partial) month is allowed; a
  # month that hasn't started yet is rejected — there is nothing to measure and accepting it invites
  # "why is next month zero" tickets.
  defp parse_period(period) do
    with %{"y" => y, "m" => m} <-
           Regex.named_captures(~r/^(?<y>\d{4})-(?<m>0[1-9]|1[0-2])$/, period),
         {year, ""} <- Integer.parse(y),
         {month, ""} <- Integer.parse(m),
         {:ok, first} <- Date.new(year, month, 1) do
      period_start = DateTime.new!(first, ~T[00:00:00], "Etc/UTC")
      next = if month == 12, do: Date.new!(year + 1, 1, 1), else: Date.new!(year, month + 1, 1)
      period_end = DateTime.new!(next, ~T[00:00:00], "Etc/UTC")

      if DateTime.compare(period_start, DateTime.utc_now()) == :gt do
        {:error, :invalid_period}
      else
        {:ok, period_start, period_end}
      end
    else
      _ -> {:error, :invalid_period}
    end
  end

  defp period_scalar(sql, app_id, period_start, period_end) do
    case Repo.query(sql, [app_id, period_start, period_end]) do
      {:ok, %{rows: [[value]]}} when is_integer(value) -> value
      _ -> 0
    end
  end

  @doc """
  Cross-tenant OPERATOR view (admin console, Surface 3): every LIVE app with owner identity, usage counts,
  key/webhook aggregates, and its test twin's existence. Deliberately separate from the owner-scoped
  `list_apps/1`, which stays untouched — this is the read-only overview billing will later consume.

  BATCHED: seven fixed queries for the WHOLE list (GROUP BY app_id), never N-per-app. The message count keeps
  the parent-conversation join (tenancy rides the conversation — the same rule the owner usage endpoint
  established). Key/webhook counts FOLD the test twin's rows into its live parent (sk_test keys live under the
  twin app_id by design, 054); usage counts are the LIVE app's own — the twin is a badge, not a row.

  NEVER selects key hashes, key prefixes, or webhook signing secrets — counts and metadata only. Owner
  identity = display_name → phone → email (what the moderation console already shows admins).
  """
  def admin_list_apps(attrs) do
    q = Map.get(attrs, "q")

    {where, params} =
      case q do
        v when is_binary(v) and v != "" -> {"AND (a.name ILIKE $1 OR a.id::text ILIKE $1)", ["%#{v}%"]}
        _ -> {"", []}
      end

    %{rows: app_rows} =
      Repo.query!(
        "SELECT a.id::text, a.name, a.created_at::text, twin.id::text AS twin_id " <>
          "FROM apps a LEFT JOIN apps twin ON twin.parent_app_id = a.id AND twin.mode = 'test' " <>
          "WHERE a.mode = 'live' #{where} ORDER BY a.created_at DESC LIMIT 200",
        params
      )

    owners = group_first(
      "SELECT o.app_id::text, o.owner_user_id::text, COALESCE(p.display_name, u.phone_number, u.email) " <>
        "FROM app_owners o JOIN users_auth u ON u.id = o.owner_user_id " <>
        "LEFT JOIN user_profiles p ON p.user_id = o.owner_user_id ORDER BY o.created_at ASC")

    users = group_count("SELECT app_id::text, count(*) FROM users_auth GROUP BY app_id")
    convos = group_count("SELECT app_id::text, count(*) FROM conversations GROUP BY app_id")

    messages =
      group_count(
        "SELECT c.app_id::text, count(*) FROM messages m " <>
          "JOIN conversations c ON c.id = m.conversation_id GROUP BY c.app_id"
      )

    storage =
      group_count(
        "SELECT app_id::text, COALESCE(SUM(size_bytes), 0)::bigint FROM media_assets GROUP BY app_id"
      )

    keys = key_counts()
    hooks = webhook_counts()

    apps =
      Enum.map(app_rows, fn [id, name, created_at, twin_id] ->
        # Twin fold: sk_test keys + test webhook endpoints live under the TWIN app_id — attribute them to
        # the live row the operator is looking at.
        scope = if twin_id, do: [id, twin_id], else: [id]

        %{
          app_id: id,
          name: name,
          created_at: created_at,
          test_twin: is_binary(twin_id),
          owner: Map.get(owners, id),
          counts: %{
            users: Map.get(users, id, 0),
            conversations: Map.get(convos, id, 0),
            messages: Map.get(messages, id, 0),
            storage_bytes: Map.get(storage, id, 0)
          },
          api_keys: sum_keys(keys, scope),
          webhooks: sum_hooks(hooks, scope)
        }
      end)

    {:ok, %{apps: apps}}
  rescue
    _ -> {:error, :app_invalid}
  end

  # app_id → %{user_id, display} for the FIRST (oldest) owner. Tenant zero and twins have no owner row → nil.
  defp group_first(sql) do
    %{rows: rows} = Repo.query!(sql, [])

    Enum.reduce(rows, %{}, fn [app_id, user_id, display], acc ->
      Map.put_new(acc, app_id, %{user_id: user_id, display: display || short_id(user_id)})
    end)
  end

  defp group_count(sql) do
    %{rows: rows} = Repo.query!(sql, [])
    Map.new(rows, fn [app_id, n] -> {app_id, n} end)
  end

  # app_id → %{live, test, revoked}. Active keys split by mode; revoked counted separately (an operator
  # cares that keys were cycled, but a revoked key is not a live credential).
  defp key_counts do
    %{rows: rows} =
      Repo.query!(
        "SELECT app_id::text, mode, (revoked_at IS NOT NULL) AS revoked, count(*) " <>
          "FROM api_keys GROUP BY app_id, mode, (revoked_at IS NOT NULL)",
        []
      )

    Enum.reduce(rows, %{}, fn [app_id, mode, revoked, n], acc ->
      key = if revoked, do: :revoked, else: if(mode == "test", do: :test, else: :live)
      Map.update(acc, app_id, %{key => n}, &Map.update(&1, key, n, fn c -> c + n end))
    end)
  end

  defp sum_keys(keys, app_ids) do
    Enum.reduce(app_ids, %{live: 0, test: 0, revoked: 0}, fn id, acc ->
      per = Map.get(keys, id, %{})
      %{
        live: acc.live + Map.get(per, :live, 0),
        test: acc.test + Map.get(per, :test, 0),
        revoked: acc.revoked + Map.get(per, :revoked, 0)
      }
    end)
  end

  defp webhook_counts do
    %{rows: rows} =
      Repo.query!(
        "SELECT app_id::text, count(*), count(*) FILTER (WHERE enabled) FROM webhook_endpoints GROUP BY app_id",
        []
      )

    Map.new(rows, fn [app_id, total, enabled] -> {app_id, %{total: total, enabled: enabled}} end)
  end

  defp sum_hooks(hooks, app_ids) do
    Enum.reduce(app_ids, %{total: 0, enabled: 0}, fn id, acc ->
      per = Map.get(hooks, id, %{total: 0, enabled: 0})
      %{total: acc.total + per.total, enabled: acc.enabled + per.enabled}
    end)
  end

  defp short_id(nil), do: "unknown"
  defp short_id(id), do: "#" <> String.slice(to_string(id), 0, 8)

  defp scalar(sql, app_id) do
    case Repo.query(sql, [app_id]) do
      {:ok, %{rows: [[value]]}} when is_integer(value) -> value
      _ -> 0
    end
  end

  defp fetch(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :app_invalid}
    end
  end
end
