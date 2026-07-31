defmodule SharedInfra.SqlFault do
  @moduledoc """
  Tells a `Postgrex.Error` that is a DOMAIN ANSWER apart from one that is a FAULT.

  `rescue Postgrex.Error -> {:error, :something_invalid}` reads as "the caller broke a rule", and for an
  integrity violation that is exactly right: a foreign-key or unique violation IS the database enforcing
  a rule, and turning it into a domain error is the intended design.

  But `Postgrex.Error` is not narrow. It is also raised for `undefined_column`, `undefined_table`,
  `datatype_mismatch`, `syntax_error` — every way a query can simply be WRONG. Those are indistinguishable
  from a domain miss once collapsed into the same `{:error, :x_invalid}`, and that is precisely how status
  and incoming media stayed 100% broken in production for days: an exception meaning "our query is broken"
  was silently returned as an ordinary negative answer.

  So: keep failing the same way (callers and HTTP mappings are unchanged), but never fail SILENTLY. An
  integrity violation returns quietly. Anything else is logged at `:error` with the full stacktrace first.

  Unlike `Ecto.Query.CastError` — which only ever fires when a caller hands a malformed id to a query cast,
  and is therefore a genuine domain miss by construction — a bare `Postgrex.Error` rescue needs this.
  """

  require Logger

  # SQLSTATE class 23 (integrity_constraint_violation) plus the serialization failures a caller can
  # legitimately retry. These mean "the database enforced a rule" — a real answer, not a defect.
  @domain_codes ~w(
    integrity_constraint_violation
    restrict_violation
    not_null_violation
    foreign_key_violation
    unique_violation
    check_violation
    exclusion_violation
  )a

  @doc "True when the error is the database enforcing a constraint, rather than a broken query."
  def domain?(%Postgrex.Error{postgres: %{code: code}}), do: code in @domain_codes
  def domain?(_), do: false

  @doc """
  Return `domain_result` — but when the exception is a FAULT rather than a constraint, log it at error
  level with the stacktrace first. `context` names the operation, e.g. `"Moderation.create_report"`.
  """
  def classify(error, stacktrace, context, domain_result) do
    unless domain?(error) do
      Logger.error(
        "#{context}: SQL FAULT (returning #{inspect(domain_result)}, but this is a BROKEN QUERY, " <>
          "not a decision): " <> Exception.format(:error, error, stacktrace)
      )
    end

    domain_result
  end
end
