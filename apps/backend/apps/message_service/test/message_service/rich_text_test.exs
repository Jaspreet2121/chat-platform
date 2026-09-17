defmodule MessageService.RichTextTest do
  @moduledoc """
  The `font` + `entities` whitelist, unit-level (no database): what is kept verbatim, what is
  dropped entry-by-entry with a counted reason, and — the case that needs its own attention — that
  span bounds are measured in UTF-16 code units, so a body with an emoji admits exactly the spans a
  JS/Kotlin client would have computed.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias MessageService.RichText

  defp entities(list, body), do: RichText.entities_metadata(%{"entities" => list}, body)

  defp entity(overrides \\ %{}),
    do: Map.merge(%{"type" => "bold", "offset" => 0, "length" => 2}, overrides)

  describe "font" do
    test "every accepted font is kept verbatim, from metadata OR the top-level attr" do
      for font <- ~w(serif rounded handwritten display elegant) do
        assert RichText.font_metadata(%{"metadata" => %{"font" => font}}) == %{"font" => font}
        assert RichText.font_metadata(%{"font" => font}) == %{"font" => font}
      end

      assert RichText.fonts() == ~w(serif rounded handwritten display elegant)
    end

    test "metadata.font wins over the top-level attr" do
      assert RichText.font_metadata(%{"metadata" => %{"font" => "serif"}, "font" => "elegant"}) ==
               %{"font" => "serif"}
    end

    test "an UNKNOWN font is dropped and logged, not kept" do
      log =
        capture_log([level: :info], fn ->
          assert RichText.font_metadata(%{"font" => "comic-sans"}) == %{}
        end)

      assert log =~ "metadata font dropped reason=unknown_font"
    end

    test "a non-string font is dropped with its own reason; absent is silent" do
      log =
        capture_log([level: :info], fn ->
          assert RichText.font_metadata(%{"font" => %{"name" => "serif"}}) == %{}
        end)

      assert log =~ "metadata font dropped reason=not_a_string"

      log = capture_log([level: :info], fn -> assert RichText.font_metadata(%{}) == %{} end)
      refute log =~ "metadata font dropped"
    end
  end

  describe "entities" do
    test "a valid list is kept in order, with exactly the canonical keys" do
      list = [
        %{"type" => "bold", "offset" => 0, "length" => 3},
        %{"type" => "link", "offset" => 4, "length" => 5, "url" => "https://example.com"},
        %{"type" => "pre", "offset" => 0, "length" => 2, "lang" => "elixir"}
      ]

      assert %{"entities" => kept} = entities(list, "0123456789")
      assert kept == list

      assert Enum.map(kept, &(Map.keys(&1) |> Enum.sort())) == [
               ["length", "offset", "type"],
               ["length", "offset", "type", "url"],
               ["lang", "length", "offset", "type"]
             ]
    end

    test "every accepted type survives" do
      body = String.duplicate("x", 10)

      for type <- RichText.types() do
        assert %{"entities" => [%{"type" => ^type}]} =
                 entities([entity(%{"type" => type})], body)
      end
    end

    test "UTF-16 BOUNDS: an emoji costs two units, so the admissible span shifts by two" do
      # "😀secret" — the emoji is units 0..1 and the word runs 2..7, total 8 units.
      body = "😀secret"
      assert RichText.utf16_length(body) == 8
      assert String.length(body) == 7

      assert %{"entities" => [_]} = entities([entity(%{"offset" => 2, "length" => 6})], body)
      # The full length in UTF-16 units is admissible …
      assert %{"entities" => [_]} = entities([entity(%{"offset" => 0, "length" => 8})], body)

      # … and one unit past it is not. Measuring CODEPOINTS (7) would have refused the valid span
      # above and accepted this one.
      log =
        capture_log([level: :info], fn ->
          assert entities([entity(%{"offset" => 0, "length" => 9})], body) == %{}
        end)

      assert log =~ "metadata entities dropped n=1 reason=out_of_range"
    end

    test "an INVALID entry is dropped on its own — the valid ones still apply" do
      body = "hello world"

      log =
        capture_log([level: :info], fn ->
          assert %{"entities" => kept} =
                   entities(
                     [
                       entity(%{"type" => "bold", "offset" => 0, "length" => 5}),
                       entity(%{"type" => "blink"}),
                       entity(%{"type" => "italic", "offset" => 6, "length" => 5})
                     ],
                     body
                   )

          assert Enum.map(kept, & &1["type"]) == ["bold", "italic"]
        end)

      assert log =~ "metadata entities dropped n=1 reason=unknown_type"
    end

    test "each rejection reason is named, and identical reasons are COUNTED into one line" do
      body = "hello world"

      cases = [
        {%{"type" => "nope"}, "unknown_type"},
        {%{"offset" => -1}, "bad_index"},
        {%{"length" => "2"}, "bad_index"},
        {%{"offset" => 10, "length" => 5}, "out_of_range"},
        {%{"type" => "bold", "url" => "https://example.com"}, "url_not_allowed"},
        {%{"type" => "link", "url" => "http://example.com"}, "bad_url"},
        {%{"type" => "link", "url" => "javascript:alert(1)"}, "bad_url"},
        {%{"type" => "link", "url" => "https://" <> String.duplicate("a", 2100)}, "bad_url"},
        {%{"type" => "bold", "lang" => "elixir"}, "lang_not_allowed"},
        {%{"type" => "pre", "lang" => String.duplicate("x", 17)}, "bad_lang"}
      ]

      for {override, reason} <- cases do
        log =
          capture_log([level: :info], fn ->
            assert entities([entity(override)], body) == %{}
          end)

        assert log =~ "metadata entities dropped n=1 reason=#{reason}",
               "#{inspect(override)} should drop with reason=#{reason}, log was: #{log}"
      end

      # Three of the same reason → ONE line saying n=3.
      log =
        capture_log([level: :info], fn ->
          assert entities(List.duplicate(entity(%{"type" => "nope"}), 3), body) == %{}
        end)

      assert log =~ "metadata entities dropped n=3 reason=unknown_type"
    end

    test "over the cap the EXCESS is dropped, not the whole list" do
      body = String.duplicate("x", 10)
      list = List.duplicate(entity(), 105)

      log =
        capture_log([level: :info], fn ->
          assert %{"entities" => kept} = entities(list, body)
          assert length(kept) == 100
        end)

      assert log =~ "metadata entities dropped n=5 reason=too_many"
      assert RichText.max_entities() == 100
    end

    test "a non-list, a non-map entry and an absent key each behave" do
      log =
        capture_log([level: :info], fn ->
          assert entities("bold please", "hello") == %{}
        end)

      assert log =~ "metadata entities dropped n=1 reason=not_a_list"

      log =
        capture_log([level: :info], fn ->
          assert entities(["bold"], "hello") == %{}
        end)

      assert log =~ "metadata entities dropped n=1 reason=not_a_map"

      log =
        capture_log([level: :info], fn ->
          assert RichText.entities_metadata(%{}, "hello") == %{}
        end)

      refute log =~ "metadata entities dropped"
    end

    test "a nil or empty body admits only a zero-length span at 0" do
      assert %{"entities" => [_]} = entities([entity(%{"length" => 0})], nil)

      log =
        capture_log([level: :info], fn ->
          assert entities([entity(%{"length" => 1})], nil) == %{}
        end)

      assert log =~ "reason=out_of_range"
    end
  end
end
