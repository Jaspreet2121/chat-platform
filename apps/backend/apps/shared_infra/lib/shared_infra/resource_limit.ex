defmodule SharedInfra.ResourceLimit do
  @moduledoc """
  Rate limiting keyed on a RESOURCE rather than on the actor.

  Every other limit in this system keys on who is calling — `contacts_sync:<user_id>`,
  `message_send:<user_id>`, `rt:write:app:<app_id>`. That shape is blind to the attack where many
  actors, each individually well behaved, converge on one object: 500 accounts draining one leaked
  group invite code are all under their own per-user limit, and the code is drained anyway.

  This module is the other axis. The budget belongs to the RESOURCE, and every actor touching it
  spends from the same pot.

  ## The key shape

      res:<resource_type>:<resource_id>:<action>

  The `res:` prefix is not decoration. Actor-keyed limits are `<action>:<subject_id>`, so without a
  separate namespace a resource id and a user id could collide in the same keyspace — and because
  both are UUIDs here, such a collision would be silent, and would show up as one user mysteriously
  consuming a group's join budget. The prefix makes the two keyspaces provably disjoint.

  `<action>` is last so one resource can carry several independent budgets (joins, previews,
  password attempts) without them sharing a counter.

  ## Composing with a per-actor limit

  Per-resource does not REPLACE per-actor — they answer different questions and both are needed:

    * per-actor stops one account abusing many resources;
    * per-resource stops many accounts abusing one resource.

  Check the per-actor limit FIRST. It is the cheaper signal, and it bounds how much of a resource's
  budget any single caller can burn — which matters because a caller who is refused downstream (an
  already-member re-join, say) has still spent from the resource's pot by the time we know that.

  ## Fail direction

  Passed in per call, no default, deliberately: a per-resource limit is usually the security control
  for its endpoint (that is generally why the resource needed its own budget), but "usually" is not
  "always", and the policy rule — fail closed when the limiter IS the security control — has to be
  answered at the call site where the trade is visible. See docs/09-devops/RATE_LIMIT_POLICY.md.
  """

  @type result ::
          :ok | {:error, :rate_limited, non_neg_integer()} | {:error, :rate_limiter_unavailable}

  @doc """
  Charge one unit against `resource_id`'s budget for `action`.

  Options:

    * `:limit` (required) — units per window
    * `:window_seconds` (required)
    * `:fail_open` (required) — `false` makes a limiter outage reject with
      `{:error, :rate_limiter_unavailable}`; `true` lets the request through

  """
  @spec check(binary(), binary(), binary(), keyword()) :: result()
  def check(resource_type, resource_id, action, opts)
      when is_binary(resource_type) and is_binary(resource_id) and is_binary(action) do
    case SharedInfra.RateLimiter.check_rate(%{
           "key" => key(resource_type, resource_id, action),
           "limit" => Keyword.fetch!(opts, :limit),
           "window_seconds" => Keyword.fetch!(opts, :window_seconds),
           "fail_open" => Keyword.fetch!(opts, :fail_open)
         }) do
      :ok ->
        :ok

      {:error, :rate_limited, retry_after_seconds} ->
        {:error, :rate_limited, retry_after_seconds}

      # Anything else is the limiter itself failing (unreachable Redis, malformed attrs). When
      # fail_open was true the limiter has already answered :ok, so reaching here means we are meant
      # to reject.
      _other ->
        {:error, :rate_limiter_unavailable}
    end
  end

  @doc "The key this module builds. Public so tests and operators can address a budget directly."
  @spec key(binary(), binary(), binary()) :: binary()
  def key(resource_type, resource_id, action),
    do: "res:" <> resource_type <> ":" <> resource_id <> ":" <> action
end
