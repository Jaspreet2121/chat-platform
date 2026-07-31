defmodule AuthService.Webhooks do
  @moduledoc """
  Webhook endpoint registry (per app). Phase 1: CRUD behind app-owner auth. The signing secret is
  generated from a CSPRNG, RETURNED ONCE at creation, and stored RECOVERABLE (plaintext — no KMS) so
  the delivery worker can HMAC-sign each POST; list/get never re-expose it. Endpoints choose which
  event types they want from a small registry.
  """

  import Ecto.Query

  alias AuthService.Repo
  alias AuthService.Schemas.WebhookEndpoint

  # The event-type registry — adding a new event type is a one-line change here (Phase 2 emits these).
  # call.started fires when a call is ANSWERED (connected); call.declined is an ACTIVE refusal, distinct from
  # call.missed (ring timeout / caller cancel) — an integrator records those differently.
  @event_types [
    "message.created",
    "conversation.created",
    "call.started",
    "call.ended",
    "call.missed",
    "call.declined"
  ]

  def event_types, do: @event_types

  @doc "Create an endpoint for an app. Returns the signing secret ONCE (under :signing_secret)."
  def create_endpoint(attrs) do
    with {:ok, app_id} <- fetch(attrs, "app_id"),
         {:ok, url} <- fetch(attrs, "url") do
      secret = generate_secret()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      %WebhookEndpoint{}
      |> WebhookEndpoint.changeset(%{
        "app_id" => app_id,
        "url" => url,
        "signing_secret" => secret,
        "enabled" => true,
        "event_types" => normalize_event_types(Map.get(attrs, "event_types")),
        "created_at" => now,
        "updated_at" => now
      })
      |> Repo.insert()
      |> case do
        # Secret shown EXACTLY ONCE — the integrator must store it now to verify signatures.
        {:ok, endpoint} -> {:ok, Map.put(public_view(endpoint), :signing_secret, secret)}
        {:error, _changeset} -> {:error, :webhook_invalid}
      end
    end
  end

  @doc "List an app's endpoints — never the signing secret."
  def list_endpoints(attrs) do
    with {:ok, app_id} <- fetch(attrs, "app_id") do
      endpoints =
        Repo.all(
          from(e in WebhookEndpoint, where: e.app_id == ^app_id, order_by: [desc: e.created_at])
        )

      {:ok, %{webhook_endpoints: Enum.map(endpoints, &public_view/1)}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :webhook_invalid}
  end

  @doc "Enable/disable an endpoint or change its event_types (scoped to the app)."
  def update_endpoint(attrs) do
    with {:ok, app_id} <- fetch(attrs, "app_id"),
         {:ok, id} <- fetch(attrs, "id"),
         %WebhookEndpoint{} = endpoint <- Repo.get_by(WebhookEndpoint, id: id, app_id: app_id) do
      changes =
        %{"updated_at" => DateTime.utc_now() |> DateTime.truncate(:microsecond)}
        |> maybe_put("enabled", boolean(Map.get(attrs, "enabled")))
        |> maybe_put("event_types", normalize_event_types(Map.get(attrs, "event_types"), nil))

      endpoint
      |> WebhookEndpoint.changeset(changes)
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, public_view(updated)}
        {:error, _changeset} -> {:error, :webhook_invalid}
      end
    else
      nil -> {:error, :not_found}
      other -> other
    end
  rescue
    Ecto.Query.CastError -> {:error, :webhook_invalid}
  end

  @doc "Delete an endpoint (scoped to the app)."
  def delete_endpoint(attrs) do
    with {:ok, app_id} <- fetch(attrs, "app_id"),
         {:ok, id} <- fetch(attrs, "id") do
      case Repo.delete_all(from(e in WebhookEndpoint, where: e.id == ^id and e.app_id == ^app_id)) do
        {1, _} -> {:ok, %{id: id, deleted: true}}
        {0, _} -> {:error, :not_found}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :webhook_invalid}
  end

  # --- Phase 4: failed-delivery ops (delegate to SharedInfra.WebhookOutbox w/ this Repo) --------

  def list_failed_deliveries(attrs) do
    cursor =
      case {Map.get(attrs, "cursor_ts"), Map.get(attrs, "cursor_id")} do
        {ts, id} when is_binary(ts) and ts != "" and is_binary(id) and id != "" -> {ts, id}
        _ -> nil
      end

    result =
      SharedInfra.WebhookOutbox.list_failed(Repo,
        app_id: presence(Map.get(attrs, "app_id")),
        event_type: presence(Map.get(attrs, "event_type")),
        limit: to_int(Map.get(attrs, "limit"), 50),
        cursor: cursor
      )

    {:ok, result}
  rescue
    Ecto.Query.CastError -> {:error, :webhook_invalid}
  end

  @doc """
  Owner-facing delivery log for ONE app (every status). `app_id` is mandatory — WebhookOutbox.list_deliveries
  refuses to run unscoped, so a missing app_id yields an empty page, never another app's rows.
  """
  def list_deliveries(attrs) do
    cursor =
      case {Map.get(attrs, "cursor_ts"), Map.get(attrs, "cursor_id")} do
        {ts, id} when is_binary(ts) and ts != "" and is_binary(id) and id != "" -> {ts, id}
        _ -> nil
      end

    result =
      SharedInfra.WebhookOutbox.list_deliveries(Repo,
        app_id: presence(Map.get(attrs, "app_id")),
        status: presence(Map.get(attrs, "status")),
        endpoint_id: presence(Map.get(attrs, "endpoint_id")),
        limit: to_int(Map.get(attrs, "limit"), 30),
        cursor: cursor
      )

    {:ok, result}
  rescue
    Ecto.Query.CastError ->
      {:error, :webhook_invalid}

    error in Postgrex.Error ->
      SharedInfra.SqlFault.classify(
        error,
        __STACKTRACE__,
        "Webhooks.write",
        {:error, :webhook_invalid}
      )
  end

  def reenqueue_delivery(attrs) do
    with {:ok, id} <- fetch(attrs, "id") do
      case SharedInfra.WebhookOutbox.reenqueue(Repo, id, actor: actor(attrs)) do
        {:ok, :reenqueued} -> {:ok, %{status: "reenqueued", id: id}}
        {:ok, :noop, reason} -> {:ok, %{status: "noop", reason: inspect(reason)}}
        {:error, _reason} -> {:error, :webhook_invalid}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :webhook_invalid}
  end

  def reenqueue_deliveries_bulk(attrs) do
    case SharedInfra.WebhookOutbox.reenqueue_bulk(
           Repo,
           [
             app_id: presence(Map.get(attrs, "app_id")),
             event_type: presence(Map.get(attrs, "event_type")),
             limit: to_int(Map.get(attrs, "limit"), 100)
           ],
           actor: actor(attrs)
         ) do
      {:ok, count} -> {:ok, %{status: "reenqueued", count: count}}
      _ -> {:error, :webhook_invalid}
    end
  rescue
    Ecto.Query.CastError -> {:error, :webhook_invalid}
  end

  defp actor(attrs), do: presence(Map.get(attrs, "actor")) || "system"
  defp presence(v) when is_binary(v) and v != "", do: v
  defp presence(_), do: nil

  defp to_int(value, _default) when is_integer(value), do: value

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      _ -> default
    end
  end

  defp to_int(_value, default), do: default

  # --- internals -------------------------------------------------------------------------------

  defp generate_secret,
    do: "whsec_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp public_view(%WebhookEndpoint{} = e) do
    %{
      id: e.id,
      app_id: e.app_id,
      url: e.url,
      enabled: e.enabled,
      event_types: e.event_types,
      created_at: iso(e.created_at),
      updated_at: iso(e.updated_at)
    }
  end

  # Keep only known event types. On create, nil → []. On update, nil → leave unchanged (sentinel).
  defp normalize_event_types(value, default \\ [])

  defp normalize_event_types(list, _default) when is_list(list),
    do: Enum.filter(list, &(&1 in @event_types))

  defp normalize_event_types(_value, default), do: default

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp boolean(value) when is_boolean(value), do: value
  defp boolean(_), do: nil

  defp fetch(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :webhook_invalid}
    end
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
