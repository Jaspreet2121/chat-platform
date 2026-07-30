defmodule SharedInfra.Attrs do
  @moduledoc """
  PRESENCE-based dual-key (atom | string) map reads.

  The pervasive `Map.get(map, :key) || Map.get(map, "key")` idiom is correct for strings/lists/ids and
  WRONG for every boolean, because `false || nil` is `nil` — a stored `false` reads as absent. That
  single footgun has produced three real bugs (read_receipts_enabled=false read as enabled;
  fail_open=false read as absent, which would have made the contacts-sync enumeration limiter fail
  OPEN; require_approval/is_host/active=false serialized as null). `get/3` decides presence with
  `Map.has_key?`, so `false` (and any other falsy-but-present value) survives.

  Use it for every BOOLEAN dual-key read, and for nullable numerics where a literal 0 must not be
  dropped (note: in Elixir only `false`/`nil` are falsy, so integer reads through `||` happen to work —
  but they read as wrong code; prefer this). Plain string/list reads may keep the `||` idiom.

  Keys are ATOMS (the callers all know the field statically); the string twin is derived — never
  `String.to_atom/1` on wire input.
  """

  @doc """
  Fetch `key` from a map that may be atom- or string-keyed, preferring the atom form, deciding
  presence with `Map.has_key?` (NOT truthiness). Returns `default` only when NEITHER form is present.

      iex> SharedInfra.Attrs.get(%{active: false}, :active)
      false
      iex> SharedInfra.Attrs.get(%{"active" => false}, :active)
      false
      iex> SharedInfra.Attrs.get(%{}, :active, :absent)
      :absent
  """
  def get(map, key, default \\ nil)

  def get(map, key, default) when is_map(map) and is_atom(key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> default
    end
  end

  def get(_map, _key, default), do: default
end
