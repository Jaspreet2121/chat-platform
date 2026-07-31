defmodule SharedInfra.SqlFaultTest do
  @moduledoc """
  The rule this module exists to enforce: a `Postgrex.Error` that is the DATABASE ENFORCING A CONSTRAINT
  is an ordinary domain answer and stays quiet; a `Postgrex.Error` that means OUR QUERY IS BROKEN returns
  the same domain answer (callers and HTTP mappings are unchanged) but is LOUD.

  This is the generalisation of the media-download bug: `rescue Postgrex.Error -> {:error, :x_invalid}`
  reads as "the caller broke a rule" and silently swallows "we shipped a broken query" alongside it.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SharedInfra.SqlFault

  defp pg(code), do: %Postgrex.Error{postgres: %{code: code, message: "boom"}}

  describe "domain?/1 — constraint violations are answers" do
    test "SQLSTATE class 23 violations are domain answers" do
      for code <- [
            :foreign_key_violation,
            :unique_violation,
            :check_violation,
            :not_null_violation,
            :exclusion_violation,
            :restrict_violation,
            :integrity_constraint_violation
          ] do
        assert SqlFault.domain?(pg(code)), "#{code} should be a domain answer"
      end
    end

    test "every way a query can simply be WRONG is NOT a domain answer" do
      for code <- [
            :undefined_column,
            :undefined_table,
            :undefined_function,
            :datatype_mismatch,
            :syntax_error,
            :invalid_text_representation,
            :insufficient_privilege
          ] do
        refute SqlFault.domain?(pg(code)), "#{code} is a fault, not a decision"
      end
    end

    test "a non-Postgrex exception is never a domain answer" do
      refute SqlFault.domain?(%RuntimeError{message: "nope"})
      refute SqlFault.domain?(:not_even_an_exception)
    end
  end

  describe "classify/4 — same answer either way, but a fault is never silent" do
    test "a constraint violation returns the domain result and logs NOTHING" do
      log =
        capture_log(fn ->
          assert SqlFault.classify(
                   pg(:foreign_key_violation),
                   [],
                   "Moderation.create_report",
                   {:error, :report_invalid}
                 ) == {:error, :report_invalid}
        end)

      refute log =~ "SQL FAULT"
    end

    test "a broken query returns THE SAME domain result but logs at error with context" do
      log =
        capture_log(fn ->
          assert SqlFault.classify(
                   pg(:undefined_column),
                   [],
                   "Moderation.create_report",
                   {:error, :report_invalid}
                 ) == {:error, :report_invalid}
        end)

      # Same answer — callers and HTTP status mappings must not change.
      assert log =~ "[error]"
      assert log =~ "SQL FAULT"
      # The operation is named, so the log says WHERE without a stacktrace read.
      assert log =~ "Moderation.create_report"
      # And it says what it returned, so "denied" is never mistaken for "decided".
      assert log =~ "report_invalid"
    end

    test "the stacktrace is included when one is supplied" do
      log =
        capture_log(fn ->
          try do
            raise pg(:syntax_error)
          rescue
            error -> SqlFault.classify(error, __STACKTRACE__, "Ctx.op", {:error, :nope})
          end
        end)

      assert log =~ "SQL FAULT"
      assert log =~ "sql_fault_test.exs"
    end
  end
end
