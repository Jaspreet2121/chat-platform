defmodule MessageService.InboxSettlementPolicy do
  @moduledoc """
  THE SINGLE SOURCE for the `inbox_read_marks` horizon pair (DECISION_LOG [2026-08-09], retention
  addendum). Two numbers live here and ONLY here; every claimant reads `fresh_enough?/1`, and any
  future prune must compute its cutoff from `prune_min_horizon_days/0` — a horizon that only one
  side knows is a time bomb, so both sides share this module or the design is broken.

  ## The rule

    * CLAIMANTS (the read decrement, the delete claim, the create-skip settle) refuse to act on
      messages older than `claim_horizon_days` — no mark inserted, no counter touched.
    * A future PRUNE may delete only marks whose message is older than `prune_min_horizon_days`
      (for legacy rows with NULL `message_created_at`, by `marked_at` instead — new marks all carry
      the real timestamp since this module landed).
    * The 3x gap between them is COMPILE-CHECKED below. It is what makes the deploy race
      unreachable by construction: any prune-eligible row has been claim-refused on every node for
      at least `prune_min - claim` days (60 at these values), and no rolling restart spans 60 days.
      No two-phase deploy choreography, no runbook step someone can skip.

  ## The topic-retention constraint — DO NOT RAISE RETENTION PAST THE CLAIM HORIZON

  `message.events.v1` retention, measured in production 2026-08-09: `retention.ms=604800000`
  (7 days, EXPLICITLY SET on the topic, not a broker default). An `:earliest` replay can redeliver
  events as old as retention; `claim_horizon_days` (30) must stay ABOVE it, or legitimately
  replayed create/delete events get refused and the 1b0bd2e interleaving guarantees silently
  degrade. If anyone ever raises topic retention past 30 days, this constant must rise with it —
  that is why this sentence lives where the constant does.

  ## Growth and the revisit threshold — measured, so nobody re-measures at low volume and panics

  Measured 2026-08-09 at 17 rows: 2409 bytes/row — that is PAGE-ALLOCATION OVERHEAD dominating
  (40 kB table minimum / 17), not real row cost. The scale estimate stands: ~230-250 bytes/row
  all-in (heap + PK + marked_at index), which at a worst-case 1k msgs/day in a 10-member group is
  ~9k rows/day ≈ ~0.8 GB/year, and decades of headroom at current traffic. THEREFORE THERE IS NO
  PRUNE — nothing scheduled ships (a scheduled writer on a guarded table is the reconciler's exact
  shape); the only behaviour this module adds is claimants DECLINING to write.

  REVISIT when `pg_total_relation_size('inbox_read_marks')` exceeds 1 GiB or the row count exceeds
  5M. The prune to write then: a MANUAL runbook action (the SearchBackfill precedent — operator-run,
  no supervision tree), cutoff from `prune_min_horizon_days/0`, run only after this module's release
  has been live longer than `prune_min - claim` days. In-code scheduling would be its own reviewed
  decision; this moduledoc is its prior art.

  ## NULL `created_at` is refused by every claimant

  `fresh_enough?(nil) == false` — a message whose age cannot be proven is not acted on. This is
  the conservative direction everywhere: no decrement (a wrong decrement steals a count from a
  different message), no settle rows, no claims. The cost is the same accepted +1-stuck class as
  auto-delete non-decay and interleaving row 8.
  """

  @claim_horizon_days 30
  @prune_min_horizon_days 90

  # THE COMPILE-TIME INVARIANT. A prune horizon inside 3x the claim horizon shrinks the
  # deploy-race margin this design depends on; changing either number forces whoever does it to
  # read this file, which is the point.
  if @prune_min_horizon_days < 3 * @claim_horizon_days do
    raise "InboxSettlementPolicy invariant violated: prune_min_horizon_days " <>
            "(#{@prune_min_horizon_days}) must be >= 3 * claim_horizon_days " <>
            "(#{@claim_horizon_days}). See the moduledoc before changing either."
  end

  @doc "Days inside which a message's counter may still be claimed (read/delete/settle)."
  def claim_horizon_days, do: @claim_horizon_days

  @doc "The FLOOR for any future prune's cutoff. See the moduledoc's prune contract."
  def prune_min_horizon_days, do: @prune_min_horizon_days

  @doc """
  May a claimant act on a message with this `created_at`? `nil` (unknown age) is always `false` —
  the conservative direction for a counter write.
  """
  def fresh_enough?(%DateTime{} = created_at) do
    horizon = DateTime.add(DateTime.utc_now(), -@claim_horizon_days * 86_400, :second)
    DateTime.compare(created_at, horizon) == :gt
  end

  def fresh_enough?(_), do: false
end
