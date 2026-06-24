defmodule SharedInfra.Correlation do
  @moduledoc """
  Correlation-id helpers for end-to-end request tracing.

  A single id flows: gateway (origin) → internal HTTP (`x-correlation-id` header) → each service
  → Kafka event envelope (`correlation_id`) → consumers. The carrier within a process is the
  Logger metadata key `:correlation_id`, so every log line on the path can be filtered by it.

  Lives in `shared_infra` (which has NO `ecto` dep), so ids are generated with `:crypto` rather
  than `Ecto.UUID` — a 32-char lowercase hex string is a perfectly good correlation id.
  """

  @header "x-correlation-id"
  @metadata_key :correlation_id
  @max_len 200

  @doc "The HTTP header name used to carry the id across service boundaries."
  @spec header() :: String.t()
  def header, do: @header

  @doc "The Logger metadata key the id is stored under within a process."
  @spec metadata_key() :: atom()
  def metadata_key, do: @metadata_key

  @doc "The correlation id from the current process's Logger metadata, or nil."
  @spec get() :: String.t() | nil
  def get, do: Logger.metadata()[@metadata_key]

  @doc "The current correlation id, or a freshly generated one (does NOT set metadata)."
  @spec get_or_generate() :: String.t()
  def get_or_generate, do: get() || generate()

  @doc "Generate a new random correlation id (32-char lowercase hex, no ecto)."
  @spec generate() :: String.t()
  def generate, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  @doc "Store `id` in the current process's Logger metadata. No-op for an invalid id."
  @spec put(term()) :: :ok
  def put(id) do
    if valid?(id), do: Logger.metadata([{@metadata_key, id}])
    :ok
  end

  @doc """
  True if `id` is a sane inbound correlation id: a non-empty, not-too-long binary. Guards against
  a hostile/garbage `x-correlation-id` header being trusted blindly.
  """
  @spec valid?(term()) :: boolean()
  def valid?(id) when is_binary(id), do: id != "" and byte_size(id) <= @max_len
  def valid?(_), do: false
end
