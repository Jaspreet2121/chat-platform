defmodule MessageService.RichText do
  @moduledoc """
  The `font` and `entities` metadata whitelist — the formatting a client sends alongside a message
  body, validated once here so every surface (timeline, `message_created`, the inbox row) carries
  the same vetted shape.

  ## Why a whitelist at all

  `MessageService.Messages.stringify_metadata/1` keeps scalars and drops every nested value, so
  today `entities` (a list) is silently destroyed and `font` (a string) survives UNVALIDATED — a
  client could store any string under it and every reader would have to defend itself. Both are now
  taken from the RAW attrs, checked, and put back in a known shape.

  ## The rules

    * `font` — one of #{inspect(~w(serif rounded handwritten display elegant))}. Anything else is
      dropped and logged. Applies to a TEXT body and a MEDIA caption.
    * `entities` — a list of at most 100 `%{type, offset, length, url?, lang?}` spans over the body
      (the caption, for media). `type` is one of #{inspect(~w(bold italic underline strikethrough spoiler code pre link quote h1 h2 bullet numbered))}.
      `offset` and `length` are non-negative integers and `offset + length` must not exceed the
      body's length IN UTF-16 CODE UNITS (`SharedInfra.Utf16` — the unit the clients count; see that
      moduledoc for why bytes and codepoints are both wrong). `url` is allowed only on `link`, must
      be `https://…` and at most 2048 characters; `lang` only on `pre`, at most 16 characters.

  ## Never a refusal

  An invalid ENTRY is dropped on its own — the rest of the list still applies — and the drop is
  logged with a count per reason. A message is never refused over its formatting: losing a bold span
  is a cosmetic regression, losing the message is data loss. (A SEALED message is different, but not
  here: its metadata builder keeps only the envelope, so a top-level `font`/`entities` is stripped
  silently on that path and never reaches this module.)
  """

  require Logger

  @fonts ~w(serif rounded handwritten display elegant)
  @types ~w(bold italic underline strikethrough spoiler code pre link quote h1 h2 bullet numbered)
  @max_entities 100
  @max_url_chars 2048
  @max_lang_chars 16

  @doc "The accepted `font` values."
  def fonts, do: @fonts

  @doc "The accepted entity `type` values."
  def types, do: @types

  @doc "The cap on how many entities one message may carry."
  def max_entities, do: @max_entities

  @doc """
  `%{"font" => font}` when the client sent a known one, `%{}` otherwise (dropped + logged).
  Read from `metadata.font` first, then the top-level `font` attr — clients send it both ways.
  """
  def font_metadata(attrs) do
    case raw(attrs, "font") do
      nil ->
        %{}

      font when font in @fonts ->
        %{"font" => font}

      other ->
        Logger.info("metadata font dropped reason=#{font_reason(other)}")
        %{}
    end
  end

  defp font_reason(value) when is_binary(value), do: "unknown_font"
  defp font_reason(_value), do: "not_a_string"

  @doc """
  `%{"entities" => [...]}` with every VALID span (order preserved), or `%{}` when none survive.
  Spans are validated against `body` — the text body, or the caption for a media message. A nil or
  empty body admits only zero-length spans at offset 0, which is what an empty body can hold.
  """
  def entities_metadata(attrs, body) do
    case raw(attrs, "entities") do
      nil ->
        %{}

      list when is_list(list) ->
        {kept, dropped} = validate_list(list, utf16_length(body))
        log_drops(dropped)
        if kept == [], do: %{}, else: %{"entities" => kept}

      _other ->
        log_drops(%{"not_a_list" => 1})
        %{}
    end
  end

  # Over the cap the EXCESS is dropped, not the whole list — a client that counts wrong still gets
  # its first 100 spans rather than a body of plain text.
  defp validate_list(list, body_units) do
    {head, excess} = Enum.split(list, @max_entities)

    dropped =
      if excess == [], do: %{}, else: %{"too_many" => Enum.count(excess)}

    Enum.reduce(head, {[], dropped}, fn raw_entity, {kept, drops} ->
      case validate_entity(raw_entity, body_units) do
        {:ok, entity} -> {kept ++ [entity], drops}
        {:error, reason} -> {kept, Map.update(drops, reason, 1, &(&1 + 1))}
      end
    end)
  end

  defp validate_entity(%{} = raw, body_units) do
    type = get(raw, "type")
    offset = get(raw, "offset")
    length = get(raw, "length")
    url = get(raw, "url")
    lang = get(raw, "lang")

    cond do
      type not in @types -> {:error, "unknown_type"}
      not index?(offset) or not index?(length) -> {:error, "bad_index"}
      offset + length > body_units -> {:error, "out_of_range"}
      not is_nil(url) and type != "link" -> {:error, "url_not_allowed"}
      not is_nil(url) and not valid_url?(url) -> {:error, "bad_url"}
      not is_nil(lang) and type != "pre" -> {:error, "lang_not_allowed"}
      not is_nil(lang) and not valid_lang?(lang) -> {:error, "bad_lang"}
      true -> {:ok, build(type, offset, length, url, lang)}
    end
  end

  defp validate_entity(_raw, _body_units), do: {:error, "not_a_map"}

  # THE CANONICAL KEY ORDER (docs/07-clients/E2EE_FRAME.md §11): type, offset, length, url, lang —
  # optional keys omitted entirely when absent, never written as null. Elixir maps are unordered, so
  # this order binds the JSON a CLIENT must build for the sealed canonical bytes; what matters here
  # is that the server stores exactly these keys and no others.
  defp build(type, offset, length, url, lang) do
    %{"type" => type, "offset" => offset, "length" => length}
    |> maybe_put("url", url)
    |> maybe_put("lang", lang)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp index?(value), do: is_integer(value) and value >= 0

  # HTTPS only: an http:// or javascript: target rendered as a tappable link is a downgrade and an
  # injection surface respectively, and no client needs either.
  defp valid_url?(url) do
    is_binary(url) and String.starts_with?(url, "https://") and
      String.length(url) <= @max_url_chars
  end

  defp valid_lang?(lang),
    do: is_binary(lang) and lang != "" and String.length(lang) <= @max_lang_chars

  defp log_drops(dropped) when map_size(dropped) == 0, do: :ok

  defp log_drops(dropped) do
    for {reason, count} <- Enum.sort(dropped) do
      Logger.info("metadata entities dropped n=#{count} reason=#{reason}")
    end

    :ok
  end

  @doc "The body length in UTF-16 code units; nil/non-binary bodies measure 0."
  def utf16_length(body) when is_binary(body), do: SharedInfra.Utf16.length(body)
  def utf16_length(_body), do: 0

  # metadata.<key> wins; the top-level attr is the fallback (both are in live client use).
  defp raw(attrs, key) do
    from_metadata =
      case get(attrs, "metadata") do
        %{} = metadata -> get(metadata, key)
        _ -> nil
      end

    if is_nil(from_metadata), do: get(attrs, key), else: from_metadata
  end

  defp get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, safe_atom(key))
    end
  end

  defp get(_map, _key), do: nil

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
