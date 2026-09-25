defmodule SharedInfra.ReasonPolicyTest do
  @moduledoc """
  The reason gate judges shapes that are never meaning. Each refused example here is one an
  operator could type to get past a length check while telling the audit reader nothing.
  """
  use ExUnit.Case, async: true

  alias SharedInfra.ReasonPolicy

  test "real reasons pass, normalised" do
    assert ReasonPolicy.validate("abuse report #4410") == {:ok, "abuse report #4410"}
    assert ReasonPolicy.validate("legal request LR-22") == {:ok, "legal request LR-22"}
    assert ReasonPolicy.validate("safety escalation") == {:ok, "safety escalation"}
    # Inner whitespace collapses; the audit row should not carry someone's double spaces.
    assert ReasonPolicy.validate("  abuse   report   #4410 ") == {:ok, "abuse report #4410"}
  end

  test "nothing at all is 'required', not 'invalid' — the caller is allowed here, they just have to say why" do
    for value <- ["", "   ", nil, 42, %{}] do
      assert ReasonPolicy.validate(value) == {:error, :required}, inspect(value)
    end
  end

  test "too short, one word, no vowels, repeated junk — each refused with a showable reason" do
    refused = [
      {"x", "at least 12 characters"},
      {"abuse rep", "at least 12 characters"},
      {"investigation", "at least two words"},
      {"hjzgjcgz hjzgjcgz", "real words — nothing here has a vowel"},
      {"asdfasdf asdfasdf", "repeated characters are not a reason"},
      {"abuse abuse abuse", "repeated characters are not a reason"},
      {"aaaaaaaaaaaa report", "repeated characters are not a reason"},
      {String.duplicate("valid words ", 20), "at most 200 characters"}
    ]

    for {value, why} <- refused do
      assert ReasonPolicy.validate(value) == {:error, {:invalid, why}}, inspect(value)
    end
  end

  test "a 10 KB string is refused outright, not truncated into an audit row" do
    assert {:error, {:invalid, _}} = ReasonPolicy.validate(String.duplicate("a", 10_000))
  end
end
