defmodule MessageService.Persistence.ScyllaCodec do
  @moduledoc """
  The ONE place Elixir terms become CQL-typed values and back. Before this module existed, the query
  plans sent whatever the domain happened to hold — ISO strings against `date`/`timestamp` columns,
  nested maps against `map<text,text>` — and none of it had ever touched a real engine, so nothing
  noticed. That is the same failure shape as the `$N::uuid` cast bug: fake-validated, engine-
  incompatible.

  ## The metadata-JSON convention (load-bearing — the poll definition depends on it)

  `metadata` is `map<text, text>` in CQL, but the domain's metadata is a JSON-ish map whose values may
  be nested maps (the ENTIRE poll definition lives at `metadata["poll"]`), integers, booleans, or
  strings. The convention:

      EVERY metadata VALUE is stored as its JSON encoding, uniformly.
      "abc" is stored as `"\\"abc\\""`, 42 as `"42"`, %{...} as `"{...}"`.
      Decoding is Jason.decode!/1 of every value, no exceptions and no sniffing.

  Uniform-JSON is chosen over "strings raw, the rest JSON" because the mixed form cannot be decoded
  unambiguously (`"123"` — int or string?). A future reader seeing `map<text,text>` in the CQL file
  MUST NOT assume it means plain strings; the schema file header says so too.

  ## Timeuuid → bucket derivation

  `bucket_date` is derived at write time from `created_at` (`Date.to_iso8601`). A point-read must
  recover the bucket from the message_id alone: the v1 timeuuid embeds a 100ns-precision timestamp,
  and `created_at` / `message_id` are generated microseconds apart in the same call
  (`Messages.create_message_in_store/1`), so the timeuuid's calendar date IS the bucket — except
  within a hair of midnight, where the two clock reads can straddle the day. `bucket_candidates/1`
  therefore returns the derived day AND the previous day; readers try both (two point reads, only at
  the boundary).
  """

  # 100ns intervals between the Gregorian epoch (1582-10-15) and the Unix epoch — the same constant
  # Messages.generate_timeuuid/0 adds, inverted here.
  @gregorian_offset 0x01B21DD213814000

  # --- uuid / timeuuid ----------------------------------------------------------------------------

  @doc "Xandra takes human-readable uuid/timeuuid strings; blank means NULL (media_id, reply_to)."
  def encode_uuid(nil), do: nil
  def encode_uuid(""), do: nil
  def encode_uuid(value) when is_binary(value), do: value

  # --- date ---------------------------------------------------------------------------------------

  @doc "CQL `date` wants %Date{}; the domain carries ISO strings."
  def encode_date(nil), do: nil
  def encode_date(%Date{} = date), do: date

  def encode_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  # --- timestamp ----------------------------------------------------------------------------------

  @doc "CQL `timestamp` wants %DateTime{}; the domain carries DateTimes OR ISO strings, historically both."
  def encode_timestamp(nil), do: nil
  def encode_timestamp(%DateTime{} = dt), do: dt

  def encode_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  # REPLACED, because it was the bug: this previously read "Responses carry ISO8601 strings (the
  # Postgres adapter's wire shape); decode symmetrically." The Postgres adapter's wire shape is NOT
  # an ISO string — the schema declares :utc_datetime_usec and it returns %DateTime{}. The comment
  # asserted a false fact and the code faithfully implemented it.
  @doc """
  Decode a CQL `timestamp` into the SAME TYPE the Postgres adapter returns: `%DateTime{}`.

  It used to return an ISO-8601 STRING, and that was the bug. `MessageStore` is one behaviour with
  two adapters; `PostgresAdapter` returns `%DateTime{}` (the schema declares `:utc_datetime_usec`)
  while this one returned a string, so anything reading a store response had to know WHICH adapter
  produced it. That is not an abstraction.

  It surfaced as `DBConnection.EncodeError` ("Postgrex expected %DateTime{}, got \"2026-…Z\"") the
  first time a consumer fed a Scylla-read message straight into a Postgres write — the inbox
  projection, which could not apply a single event. The same shape as `limit` arriving as the string
  "50": the engines were real, the calling convention was not.

  Serialisation to ISO-8601 belongs at the WIRE edge, not in the store. `Messages.iso8601/1` already
  does it for the public response, and Jason encodes `%DateTime{}` for the Kafka envelope.
  """
  def decode_timestamp(nil), do: nil
  def decode_timestamp(%DateTime{} = dt), do: dt

  def decode_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      # An unparseable timestamp is returned untouched rather than raising: a decode helper must not
      # be able to take down a read. The caller sees a string and fails loudly at ITS boundary.
      _ -> value
    end
  end

  # --- metadata (the JSON convention) -------------------------------------------------------------

  def encode_metadata(nil), do: %{}

  def encode_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {key, value} -> {to_string(key), Jason.encode!(value)} end)
  end

  def decode_metadata(nil), do: %{}

  def decode_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {key, value} -> {key, Jason.decode!(value)} end)
  end

  # --- timeuuid timestamp extraction --------------------------------------------------------------

  @doc """
  The calendar date(s) a v1 timeuuid's embedded timestamp may have been bucketed under: the derived
  day plus the previous day (the midnight race described in the moduledoc). Errors → [] (malformed id
  → not found, never a crash).
  """
  def bucket_candidates(timeuuid) when is_binary(timeuuid) do
    case timeuuid_to_datetime(timeuuid) do
      {:ok, %DateTime{} = dt} ->
        day = DateTime.to_date(dt)
        [day, Date.add(day, -1)]

      _ ->
        []
    end
  end

  @doc "Extract the embedded 100ns timestamp from a v1 timeuuid string as a UTC DateTime."
  def timeuuid_to_datetime(<<
        time_low::binary-size(8),
        "-",
        time_mid::binary-size(4),
        "-",
        time_hi::binary-size(4),
        "-",
        _rest::binary
      >>) do
    with {low, ""} <- Integer.parse(time_low, 16),
         {mid, ""} <- Integer.parse(time_mid, 16),
         {hi, ""} <- Integer.parse(time_hi, 16),
         # v1 check: version nibble is the top hex digit of time_hi.
         1 <- Bitwise.bsr(hi, 12) do
      hundred_ns =
        Bitwise.band(hi, 0x0FFF)
        |> Bitwise.bsl(48)
        |> Bitwise.bor(Bitwise.bsl(mid, 32))
        |> Bitwise.bor(low)
        |> Kernel.-(@gregorian_offset)

      DateTime.from_unix(div(hundred_ns, 10), :microsecond)
    else
      _ -> {:error, :not_a_v1_timeuuid}
    end
  end

  def timeuuid_to_datetime(_other), do: {:error, :not_a_v1_timeuuid}
end
