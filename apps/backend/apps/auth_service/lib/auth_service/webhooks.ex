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
  @event_types ["message.created", "conversation.created"]

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
