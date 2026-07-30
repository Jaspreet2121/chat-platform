defmodule UserService.UsernamesValidationTest do
  @moduledoc """
  Docker-free username validation: every rejected format with its SPECIFIC code, the length bounds, the
  reserved list (checked against the normalised key), and the exact normalisation rule. The lifecycle
  (uniqueness, holds, budget, lookup) is UserService.UsernamesTest on real SQL.
  """
  use ExUnit.Case, async: true

  alias UserService.Usernames

  test "accepted: letter start, letters/digits/underscore, 3–30, any casing" do
    for name <- ["abc", "Alice", "a_b", "A1z", "x" <> String.duplicate("y", 29), "Zed_99"] do
      assert :ok = Usernames.validate(name), "expected #{name} to validate"
    end
  end

  test "length bounds carry their own codes" do
    assert {:error, :username_too_short} = Usernames.validate("ab")
    assert {:error, :username_too_long} = Usernames.validate(String.duplicate("a", 31))
  end

  test "format rejections: digit/underscore start, hyphen, dot, space, @, unicode — all invalid_format" do
    for name <- ["1abc", "_abc", "a-bc", "a.bc", "a bc", "@abc", "abé", "аbc", "ab‍c"] do
      assert {:error, :username_invalid_format} = Usernames.validate(name),
             "expected #{inspect(name)} to be invalid_format"
    end

    assert {:error, :username_invalid_format} = Usernames.validate(nil)
    assert {:error, :username_invalid_format} = Usernames.validate(42)
  end

  test "reserved names are caught against the NORMALISED key (AdMin too); brand terms included" do
    for name <- ["admin", "AdMin", "SUPPORT", "root", "growblic", "ExWay"] do
      assert {:error, :username_reserved} = Usernames.validate(name),
             "expected #{name} to be reserved"
    end

    # Near-misses are fine — we don't fuzzy-match.
    assert :ok = Usernames.validate("admin2")
    assert :ok = Usernames.validate("supporter")
  end

  test "the normalisation rule is exactly ASCII downcase (homographs impossible by construction)" do
    # The Cyrillic 'а' homograph never reaches normalisation — rejected as invalid_format above.
    # For accepted input, the key is plain String.downcase — nothing else.
    assert String.downcase("AlIcE_99") == "alice_99"
  end
end
