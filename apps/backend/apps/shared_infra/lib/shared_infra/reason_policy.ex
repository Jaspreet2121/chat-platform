defmodule SharedInfra.ReasonPolicy do
  @moduledoc """
  What counts as a REASON for reading personal data — one rule, shared by the server and mirrored
  by the console, so an operator is never told "fine" by the page and "no" by the API.

  A reason is recorded against the operator's name, IP and the time, and read back months later
  by someone reconstructing why an access happened. "hjzgjcgz" tells that person nothing, and a
  gate that accepted it was a gate that measured typing, not intent. So a reason must be long
  enough to say something (12+ characters), be more than one word, contain a vowel (the cheapest
  test for "these are words"), and not be the same characters over and over — "asdfasdf" and
  "abuse abuse abuse" both fail that last one.

  This cannot judge meaning; it judges the shapes that are never meaning. Anything past it is a
  human's responsibility, which is what the audit row is for.
  """

  @min_length 12
  @max_length 200

  def min_length, do: @min_length
  def max_length, do: @max_length

  @doc """
  `{:ok, normalised}` — trimmed, inner whitespace collapsed — or `{:error, :required}` for nothing
  at all, or `{:error, {:invalid, why}}` with a short, showable `why`.
  """
  @spec validate(term()) ::
          {:ok, String.t()} | {:error, :required} | {:error, {:invalid, String.t()}}
  def validate(value) do
    reason = if is_binary(value), do: normalise(value), else: ""

    cond do
      reason == "" ->
        {:error, :required}

      String.length(reason) < @min_length ->
        {:error, {:invalid, "at least #{@min_length} characters"}}

      String.length(reason) > @max_length ->
        {:error, {:invalid, "at most #{@max_length} characters"}}

      word_count(reason) < 2 ->
        {:error, {:invalid, "at least two words"}}

      not vowel?(reason) ->
        {:error, {:invalid, "real words — nothing here has a vowel"}}

      junk?(reason) ->
        {:error, {:invalid, "repeated characters are not a reason"}}

      true ->
        {:ok, reason}
    end
  end

  defp normalise(value), do: value |> String.trim() |> String.replace(~r/\s+/u, " ")

  # A "word" is two or more letters/digits in a row: "#4410" counts, a stray "-" does not.
  defp word_count(reason), do: length(Regex.scan(~r/[\p{L}\p{N}]{2,}/u, reason))

  defp vowel?(reason), do: String.downcase(reason) =~ ~r/[aeiou]/

  # Junk = the same character four or more times in a row, or the whole thing being one short
  # pattern repeated. Letters only, lowercased, so spaces and punctuation cannot disguise it.
  defp junk?(reason) do
    letters = reason |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]/u, "")
    run?(letters) or periodic?(letters)
  end

  defp run?(letters), do: letters =~ ~r/(.)\1{3,}/u

  defp periodic?(letters) do
    len = String.length(letters)

    len >= 2 and
      Enum.any?(1..div(len, 2), fn period ->
        rem(len, period) == 0 and
          String.duplicate(String.slice(letters, 0, period), div(len, period)) == letters
      end)
  end
end
