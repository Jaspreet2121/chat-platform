defmodule SharedInfra.Logging.JsonFormatter do
  @moduledoc """
  Hand-rolled JSON log formatter (no new dep — uses Jason, already present) for prod, so logs are
  structured and queryable by `request_id` / `correlation_id` in a log aggregator.

  Wired in `config/prod.exs` only; dev/test keep the plain console format. A formatter MUST NOT
  raise (it runs in the logger path), so every branch is defensive and falls back to a plain line.

  Used as `format: {SharedInfra.Logging.JsonFormatter, :format}` with `metadata: :all`.
  """

  @doc "Logger format/4 callback. Returns an iodata JSON line ending in a newline."
  @spec format(atom(), IO.chardata() | String.Chars.t(), tuple(), keyword()) :: IO.chardata()
  def format(level, message, timestamp, metadata) do
    entry =
      metadata
      |> Enum.map(fn {key, value} -> {to_string(key), safe(value)} end)
      |> Map.new()
      |> Map.merge(%{
        "time" => format_time(timestamp),
        "level" => to_string(level),
        "message" => to_string_safe(message)
      })

    [Jason.encode_to_iodata!(entry), ?\n]
  rescue
    _ -> [to_string_safe(message), ?\n]
  end

  # Keep values JSON-encodable: pass through primitives, stringify atoms, inspect the rest
  # (pids, refs, tuples, structs without Jason.Encoder, etc.) so encoding never fails.
  defp safe(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp safe(value) when is_atom(value), do: Atom.to_string(value)
  defp safe(value) when is_list(value) or is_map(value), do: safe_encodable(value)
  defp safe(value), do: inspect(value)

  # Lists/maps may contain non-encodable terms; fall back to inspect if Jason would choke.
  defp safe_encodable(value) do
    case Jason.encode(value) do
      {:ok, _} -> value
      {:error, _} -> inspect(value)
    end
  end

  defp to_string_safe(message) do
    IO.iodata_to_binary(message)
  rescue
    _ -> inspect(message)
  end

  defp format_time({{year, month, day}, {hour, minute, second, millisecond}}) do
    :io_lib.format(
      "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~3..0BZ",
      [year, month, day, hour, minute, second, millisecond]
    )
    |> IO.iodata_to_binary()
  rescue
    _ -> ""
  end

  defp format_time(_), do: ""
end
