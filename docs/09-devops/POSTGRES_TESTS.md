# Running the postgres-gated test suites

The `@tag :postgres_integration` suites are excluded from `mix test` so the default path stays
Docker-free. Everything that actually executes them goes through **one** script:

```bash
./scripts/test-postgres.sh                    # every postgres-gated suite
./scripts/test-postgres.sh apps/message_service/test/message_service/statuses_test.exs
```

It boots Postgres (compose locally, the service container in CI), rebuilds `chat_platform_test` from
`infra/docker/postgres/init/*.sql` in filename order, then runs each suite **separately**.

The GitHub Actions `integration` job in [`.github/workflows/backend-ci.yml`](../../.github/workflows/backend-ci.yml)
**invokes this same script**. It does not restate the commands — that drift is how "runs in your CI"
stayed believable while nothing ran.

## Why this exists

Status and incoming media both shipped **100% broken** on a Postgrex parameter-cast bug (`$N::uuid`
against a string raises `DBConnection.EncodeError`; it must be `$N::text::uuid`). Neither feature had
ever executed against a real database. Compiling proves nothing about raw SQL — parameter encoding
fails at runtime.

CI was not absent. It ran on every push and had been **red for 12+ consecutive runs**, because both
jobs used `mix compile --warnings-as-errors` and a single pre-existing warning failed the compile step
— so the test step never ran at all, and permanent red made the signal worthless. The `integration`
job now compiles without `--warnings-as-errors` (the fast `backend` job still owns that lint gate), so
a lint regression can never again hide a database regression.

## Two operational facts

**A single umbrella-wide run is not a trustworthy signal.** All apps share the one `chat_platform_test`
database, so suites interfere. Two identical runs of `mix test --include postgres_integration` were
observed to **disagree on 33 tests**. Per-suite is the only honest read — which is what the script
does. The same applies to plain `mix test`: the api_gateway/media_service placeholder and MinIO tests
flake by ~8 tests run to run, so judge a change by diffing against a `git stash` baseline, never by
reading a raw failure count.

**`cd apps/<app> && mix test` has been broken since the Scylla Phase-B work.** Xandra declares
`decimal ~> 1.7 or ~> 2.0` as an *optional* dep and Hex enforces optional constraints when the package
is present, so the build needs `{:decimal, "~> 3.0", override: true}` — which lives only in the **root**
`apps/backend/mix.exs`. A per-app run does not inherit it and dies with `Unchecked dependencies`.
Always run from the umbrella root.

## Known follow-ups (not fixed)

1. **Per-app test databases** — the real fix for the shared-DB flakiness above. Every service Repo
   currently points at the single `chat_platform_test`; giving each app its own database (or schema)
   would make an umbrella-wide run meaningful again and let suites run concurrently. Until then the
   per-suite loop is a workaround, not a solution.

2. **`admin_scope_analytics_postgres_integration_test.exs` has a stale fixture** — its setup seeds
   `messages` without `app_id`, which has since become `NOT NULL`, so the suite fails in `setup` with
   `23502 not_null_violation` and has never passed. The seed helper needs an `app_id`.

3. **`media_persistence_postgres_integration_test.exs` needs real MinIO bytes** — the two
   `complete_upload` cases return `{:error, :verify_failed}` because verification looks for an object
   that no test ever uploads. They need either a real PUT against the MinIO service or an injected
   storage adapter. The script's per-suite output makes these two visible instead of lost in an
   aggregate.

4. **~150 files fail `mix format --check-formatted`** — and that step runs *before* compile in the
   fast `backend` job, so **that job has never reached its test step either**. The `integration` job
   has no format step and is unblocked by the compile fix above, but the overall CI run stays red
   until this is cleared. The fix is one mechanical command (`cd apps/backend && mix format`), kept
   out of the CI-plumbing commit deliberately: a 150-file reformat would bury every real change it
   was committed alongside. It wants its own commit and its own review.
