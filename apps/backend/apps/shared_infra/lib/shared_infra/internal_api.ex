defmodule SharedInfra.InternalApi do
  @moduledoc """
  Shared serialization for the INTERNAL service-to-service HTTP APIs (distinct from the
  gateway's PUBLIC user-facing error envelope, which lives in api_gateway and is untouched).

  Every internal service API encodes its in-process result through `encode_result/1`, and the
  future HTTP client adapters reconstruct the EXACT in-process shape through `decode_result/1`.
  The contract preserves error ATOMS (the gateway pattern-matches on them) and rehydrates
  atom-keyed response maps, so the HTTP path is shape-identical to the in-process path.

  Result-envelope (the wire contract — see docs/09-devops/INTERNAL_API.md):
    * `{:ok, map}`        ⇄ `{"ok": <map>}`              (map keys round-trip to atoms)
    * `{:error, atom}`    ⇄ `{"error": "<atom_name>"}`   (atom preserved via to_existing_atom)
    * bare value (e.g. `persistence_enabled?` boolean) ⇄ `{"result": <value>}`

  All internal responses are HTTP 200 (the ok/error is a DOMAIN result carried in the body, not
  a transport error). Transport-auth failures are 401 (see `TokenPlug`).
  """

  @doc "Encode an in-process result into the internal wire envelope (a JSON-encodable map)."
  def encode_result({:ok, value}), do: %{"ok" => value}

  def encode_result({:error, reason}) when is_atom(reason),
    do: %{"error" => Atom.to_string(reason)}

  def encode_result({:error, reason}), do: %{"error" => inspect(reason)}
  def encode_result(value), do: %{"result" => value}

  @doc """
  Decode the internal wire envelope (a JSON-decoded, string-keyed map) back into the in-process
  result shape. Map keys are rehydrated to atoms via `String.to_existing_atom/1` (the atoms
  exist in the service code); error names likewise. Unknown keys/atoms fall back to the string
  (never crashes).

  `opts[:skip_atomize]` is a list of string keys whose VALUE is left untouched (NOT recursed into /
  atomized) at any depth — for FREE-FORM, user-provided maps like a message's `metadata`. Atomizing
  those would (a) mint arbitrary atoms from user input (atom-table exhaustion) and (b) change the
  shape vs in-process (where `metadata` stays string-keyed). Default `[]` → fully atomized (the
  behavior the other adapters rely on; unchanged).
  """
  def decode_result(envelope, opts \\ [])

  def decode_result(%{"ok" => value}, opts), do: {:ok, atomize_keys(value, skip(opts))}

  def decode_result(%{"error" => name}, _opts) when is_binary(name),
    do: {:error, safe_existing_atom(name)}

  def decode_result(%{"result" => value}, _opts), do: value

  defp skip(opts), do: Keyword.get(opts, :skip_atomize, [])

  @doc "Configured internal service-to-service token (nil if unset → TokenPlug fails closed)."
  def internal_token, do: Application.get_env(:shared_infra, :internal_api_token)

  defp atomize_keys(map, skip) when is_map(map) do
    Map.new(map, fn {k, v} ->
      # A skipped key keeps its VALUE verbatim (free-form map left string-keyed), but the key
      # itself is still atomized so siblings/shape match the in-process result.
      value = if is_binary(k) and k in skip, do: v, else: atomize_value(v, skip)
      {safe_key(k), value}
    end)
  end

  defp atomize_keys(value, _skip), do: value

  defp atomize_value(v, skip) when is_map(v), do: atomize_keys(v, skip)
  defp atomize_value(v, skip) when is_list(v), do: Enum.map(v, &atomize_value(&1, skip))
  defp atomize_value(v, _skip), do: v

  defp safe_key(k) when is_binary(k), do: safe_existing_atom(k)
  defp safe_key(k), do: k

  defp safe_existing_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end
end

defmodule SharedInfra.InternalApi.TokenPlug do
  @moduledoc """
  Internal service-to-service auth plug — a NEW security surface. Requires the
  `x-internal-token` header to match the configured `:shared_infra, :internal_api_token`
  (constant-time compare). FAILS CLOSED: if no token is configured, every request is rejected.
  Intended to run on a PRIVATE network (Fly 6PN / docker network); the token is defense in depth.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    expected = SharedInfra.InternalApi.internal_token()
    provided = conn |> get_req_header("x-internal-token") |> List.first()

    if is_binary(expected) and is_binary(provided) and
         Plug.Crypto.secure_compare(expected, provided) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, Jason.encode!(%{"error" => "unauthorized"}))
      |> halt()
    end
  end
end
