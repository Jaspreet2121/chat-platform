defmodule SharedInfra.Events.Envelope do
  @moduledoc """
  Builds and validates the standard event envelope.

  Shape is the "Standard Event Envelope" from docs/07-events/KAFKA_EVENT_CATALOG.md:

    Required: event_id, event_type, event_version (integer), producer,
              occurred_at (ISO8601 string), correlation_id, payload (map)
    Optional: tenant_id, actor_user_id

  Pure functions, no IO and no broker coupling — this is the event contract so
  every producer emits a consistent shape. Callers supply ids/timestamps
  (event_id / occurred_at / correlation_id) so the functions stay deterministic.
  """

  @required [
    :event_id,
    :event_type,
    :event_version,
    :producer,
    :occurred_at,
    :correlation_id,
    :payload
  ]
  @optional [:tenant_id, :actor_user_id]
  @all @required ++ @optional

  @type t :: %{optional(atom()) => term()}
  @type result :: {:ok, t()} | {:error, {:invalid_envelope, [atom()]}}

  @doc """
  Builds a normalized envelope from `attrs` (atom- or string-keyed), applying
  safe defaults (`event_version: 1`, `payload: %{}`) and then validating.
  """
  @spec build(map()) :: result()
  def build(attrs) when is_map(attrs) do
    provided = take_known(attrs)

    %{event_version: 1, payload: %{}, tenant_id: nil, actor_user_id: nil}
    |> Map.merge(provided)
    |> validate()
  end

  @doc """
  Validates an envelope: all required fields present/non-blank, `event_version`
  an integer, `payload` a map. Returns the normalized (known-keys-only) map.
  """
  @spec validate(map()) :: result()
  def validate(envelope) when is_map(envelope) do
    normalized = take_known(envelope)

    with :ok <- ensure_present(normalized),
         :ok <- ensure_types(normalized) do
      {:ok, normalized}
    end
  end

  defp ensure_present(envelope) do
    case Enum.filter(@required, fn key -> blank?(Map.get(envelope, key)) end) do
      [] -> :ok
      missing -> {:error, {:invalid_envelope, missing}}
    end
  end

  defp ensure_types(envelope) do
    bad =
      []
      |> prepend_unless(is_integer(Map.get(envelope, :event_version)), :event_version)
      |> prepend_unless(is_map(Map.get(envelope, :payload)), :payload)

    if bad == [], do: :ok, else: {:error, {:invalid_envelope, bad}}
  end

  defp prepend_unless(list, true, _key), do: list
  defp prepend_unless(list, false, key), do: [key | list]

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # Pulls only known envelope keys (accepting atom or string keys), ignoring
  # anything else — avoids String.to_atom on untrusted input.
  defp take_known(map) do
    Enum.reduce(@all, %{}, fn key, acc ->
      cond do
        Map.has_key?(map, key) ->
          Map.put(acc, key, Map.get(map, key))

        Map.has_key?(map, Atom.to_string(key)) ->
          Map.put(acc, key, Map.get(map, Atom.to_string(key)))

        true ->
          acc
      end
    end)
  end
end
