defmodule ApiGatewayWeb.AdminEventOutboxController do
  @moduledoc """
  Operator surface for the kafka event outbox (096) — the webhook dead-letter ops precedent
  adapted to the event pipeline. READ + one one-way acknowledge; THE RELAY IS THE ONLY PUBLISHER —
  no action here can move a row toward staged/pending, and `acknowledged` is a state the relay's
  queries cannot see.

  Permissions REUSE the webhook pair (recorded decision, 2026-08-10): `webhooks.view` /
  `webhooks.manage` cover delivery-pipeline ops broadly — webhook outbox AND event outbox. The
  single-row expand (`show/2`, which carries the envelope) rides `webhooks.view` like the lists:
  it is a read, and the expand itself is the envelope-visibility gate, not a higher permission —
  displayable because the envelope payload is thin by design (ids, never message content).

  First-party machinery, global-admin-only: unlike the webhook ops surface there is no per-app
  scoping, because the event pipeline is not per-integrator data.
  """

  use ApiGatewayWeb, :controller

  plug ApiGatewayWeb.Plugs.RequirePermission,
       "webhooks.view" when action in [:summary, :index, :show]

  plug ApiGatewayWeb.Plugs.RequirePermission, "webhooks.manage" when action in [:acknowledge]

  alias ApiGatewayWeb.ErrorResponse

  # GET /api/v1/admin/events/outbox — per-state counts + max ages. Zeros mean health; staged max
  # age past ~90s is the relay-health proxy.
  def summary(conn, _params) do
    case SharedInfra.MessageClient.event_outbox_summary(%{}) do
      {:ok, result} ->
        json(conn, result)

      {:error, :message_unavailable} ->
        ErrorResponse.service_unavailable(conn, "events.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "events.invalid_request")
    end
  end

  # GET /api/v1/admin/events/outbox/rows?status=&limit=&cursor= — metadata only, keyset-paginated.
  def index(conn, params) do
    {cursor_ts, cursor_id} = decode_cursor(Map.get(params, "cursor"))

    attrs =
      %{
        "status" => Map.get(params, "status"),
        "limit" => Map.get(params, "limit"),
        "cursor_ts" => cursor_ts,
        "cursor_id" => cursor_id
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case SharedInfra.MessageClient.event_outbox_list(attrs) do
      {:ok, result} ->
        json(conn, %{
          data: get(result, :items) || [],
          count: get(result, :count) || 0,
          next_cursor: encode_cursor(get(result, :next_cursor))
        })

      {:error, :message_unavailable} ->
        ErrorResponse.service_unavailable(conn, "events.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "events.invalid_request")
    end
  end

  # GET /api/v1/admin/events/outbox/:id — the explicit expand, envelope included.
  def show(conn, %{"id" => id}) do
    case SharedInfra.MessageClient.event_outbox_get(%{"id" => id}) do
      {:ok, result} ->
        json(conn, result)

      {:error, :event_not_found} ->
        ErrorResponse.not_found(conn, "events.not_found", "Not found")

      {:error, :message_unavailable} ->
        ErrorResponse.service_unavailable(conn, "events.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "events.invalid_request")
    end
  end

  # POST /api/v1/admin/events/outbox/:id/acknowledge — aborted -> acknowledged, one way, evidence
  # (last_error) preserved. "noop" (409) for any row not currently aborted.
  def acknowledge(conn, %{"id" => id}) do
    case SharedInfra.MessageClient.event_outbox_acknowledge(%{"id" => id}) do
      {:ok, result} ->
        case get(result, :status) do
          "acknowledged" -> json(conn, result)
          "noop" -> conn |> put_status(:conflict) |> json(result)
          _ -> json(conn, result)
        end

      {:error, :message_unavailable} ->
        ErrorResponse.service_unavailable(conn, "events.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "events.invalid_request")
    end
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp decode_cursor(nil), do: {nil, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [ts, id] <- String.split(decoded, "|", parts: 2) do
      {ts, id}
    else
      _ -> {nil, nil}
    end
  end

  defp encode_cursor(nil), do: nil

  defp encode_cursor(%{ts: ts, id: id}), do: encode_cursor_parts(ts, id)

  defp encode_cursor(%{"ts" => ts, "id" => id}), do: encode_cursor_parts(ts, id)

  defp encode_cursor(_), do: nil

  defp encode_cursor_parts(ts, id),
    do: Base.url_encode64("#{ts}|#{id}", padding: false)
end
