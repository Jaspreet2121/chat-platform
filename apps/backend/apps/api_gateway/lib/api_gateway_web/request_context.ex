defmodule ApiGatewayWeb.RequestContext do
  @moduledoc """
  The request facts an audit row needs: who the call really came from, and what it was made with.

  ONE definition, shared by the rate limiter (which keys on the IP) and the admin audit writer
  (which records it). A second derivation would be worse than none: `audit_logs.ip_address` filled
  with Caddy's bridge address looks like evidence and is not.
  """

  import Plug.Conn

  @doc """
  THE REAL CLIENT IP, not the proxy's. Every request reaches this app through Caddy, so
  `conn.remote_ip` is the Caddy container's bridge address — identical for every caller.

  We take the LAST `x-forwarded-for` entry, not the first. A client can send its own header; Caddy
  APPENDS the address it actually observed, so the rightmost entry is the one value the client
  cannot forge. Taking the leftmost (what `Plug.RewriteOn` does) would let an attacker write any
  address they like into the audit log. Correct because there is exactly ONE trusted proxy in front
  of this app and the gateway port is not published — revisit if either changes.
  """
  @spec client_ip(Plug.Conn.t()) :: String.t()
  def client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [] ->
        peer_ip(conn)

      headers ->
        headers
        |> Enum.join(",")
        |> String.split(",")
        |> List.last()
        |> String.trim()
        |> case do
          "" -> peer_ip(conn)
          address -> address
        end
    end
  end

  @doc """
  The caller's `user-agent`, truncated. Free-form client input, so it is bounded before it reaches a
  `text` column — an audit row is evidence, not a place to store 8 KB somebody chose.
  """
  @spec user_agent(Plug.Conn.t()) :: String.t() | nil
  def user_agent(conn) do
    case get_req_header(conn, "user-agent") do
      [value | _] when is_binary(value) and value != "" -> String.slice(value, 0, 400)
      _ -> nil
    end
  end

  @doc "Both facts, as the string-keyed attrs the internal API carries to the audit writer."
  @spec audit_attrs(Plug.Conn.t()) :: %{String.t() => String.t() | nil}
  def audit_attrs(conn) do
    %{"ip_address" => client_ip(conn), "user_agent" => user_agent(conn)}
  end

  # :inet.ntoa renders IPv4 and IPv6 correctly.
  defp peer_ip(%{remote_ip: remote_ip}) when is_tuple(remote_ip) do
    case :inet.ntoa(remote_ip) do
      address when is_list(address) -> List.to_string(address)
      _ -> "unknown"
    end
  end

  defp peer_ip(_conn), do: "unknown"
end
