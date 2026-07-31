defmodule ApiGatewayWeb.V1.PresenceController do
  @moduledoc """
  Public `/v1` presence read for integrator SDKs. `GET /v1/presence?user_ids=a,b,c` → the online/last-seen
  snapshot for those users AS THE CALLER may see them (privacy-filtered, fail-closed; see
  `ApiGatewayWeb.PresenceRead`). END-USER token only — presence is a per-user relation, and an app-actor has
  no user to authorize against.

  This is the snapshot a client loads before it subscribes for live updates over the socket.

  ID BOUNDARY: the SDK speaks EXTERNAL ids, but presence (shared-conversation authz + the online store) is
  keyed on INTERNAL ids — the same mismatch that broke `subscribe`. So this resolves each requested external
  id → internal (within the caller's app), runs the internal-keyed snapshot, and relabels every result back to
  the EXTERNAL id. `PresenceRead` itself stays internal-only; the id-bridge lives here. An external id that
  doesn't resolve is reported as offline (fail-closed) under its original external id — never a leak, never a
  crash, and no internal uuid ever crosses the /v1 boundary.
  """
  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse
  alias ApiGatewayWeb.PresenceRead

  def index(conn, params) do
    case conn.assigns[:v1_user_id] do
      caller when is_binary(caller) and caller != "" ->
        app_id = conn.assigns[:v1_app_id]
        externals = PresenceRead.parse_ids(params["user_ids"])

        # external → internal, keeping the pairing so results can be relabeled back to external.
        resolved = Enum.map(externals, fn ext -> {ext, resolve_internal(ext, app_id)} end)
        internals = for {_ext, internal} when is_binary(internal) <- resolved, do: internal

        # Internal-keyed snapshot → a map internal => entry, so each external can pick up its own.
        by_internal =
          caller
          |> PresenceRead.snapshot(internals)
          |> Map.new(fn %{user_id: internal} = entry -> {internal, entry} end)

        presence =
          Enum.map(resolved, fn
            {ext, internal} when is_binary(internal) ->
              case Map.get(by_internal, internal) do
                %{online: online, last_seen_at: last_seen} ->
                  %{user_id: ext, online: online, last_seen_at: last_seen}

                # Resolved but the snapshot dropped it (shouldn't happen) → fail-closed offline.
                _ ->
                  offline(ext)
              end

            # Unresolvable external id → fail-closed offline under its original id.
            {ext, _} ->
              offline(ext)
          end)

        json(conn, %{presence: presence})

      _ ->
        ErrorResponse.forbidden(
          conn,
          "v1.end_user_only",
          "This endpoint requires an end-user token"
        )
    end
  end

  defp offline(user_id), do: %{user_id: user_id, online: false, last_seen_at: nil}

  # Resolve-ONLY: this is a GET — an unknown external id must read as offline, never CREATE a user row
  # (which the resolve-or-create variant would). Outcome identical to before: nil → offline under the id.
  defp resolve_internal(external, app_id)
       when is_binary(app_id) and app_id != "" and is_binary(external) do
    case SharedInfra.AuthClient.lookup_external_user(%{
           "app_id" => app_id,
           "external_id" => external
         }) do
      {:ok, res} -> Map.get(res, :user_id) || Map.get(res, "user_id")
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp resolve_internal(_external, _app_id), do: nil
end
