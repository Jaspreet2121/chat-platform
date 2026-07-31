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

## Exclusion convention

A suite that genuinely cannot run here carries an **explicit named tag saying why** —
`@moduletag :requires_kafka`, `:requires_minio` — never a bare skip. `test-postgres.sh` prints the
excluded suites and their count on **every** run, including when the count is zero:

```
==> 56 postgres-gated suites; 0 excluded
```

Silent exclusion is how "runs in your CI" stayed believable while nothing ran. An exclusion nobody
sees is indistinguishable from a test that does not exist.

## Known follow-ups

1. **Per-app test databases** — the real fix for the shared-database flakiness described above. Every
   service Repo points at the single `chat_platform_test`, so an umbrella-wide run interferes with
   itself. The per-suite loop is a workaround, not a solution; per-app databases (or schemas) would
   make an aggregate run meaningful again and let suites run concurrently.

2. **Elixir version pinning** — `mix format` output is version-dependent (1.20 collapses
   `when guard, do: :ok` onto one line, 1.18 splits it), and the version is declared in exactly one
   place: the CI workflow. Formatting on a newer local Elixir re-breaks CI. A `.tool-versions` pinning
   1.18.4 would close this.

### Resolved

- ~~`admin_scope_analytics` stale fixture~~ — seeded `messages` without the now-`NOT NULL` `app_id`;
  fixed, along with five sibling suites that predated the same tenant-anchoring change.
- ~~`media_persistence` needs real MinIO bytes~~ — it does not. The size-verification path is already
  proven end-to-end by `MediaService.CompleteVerifyTest` (over-cap deletion, missing PUT, fail-closed,
  measured-size-over-claim). Those two cases are about the ownership predicate and idempotency, so
  they now use an in-memory adapter that reports a stored size rather than adding a networked service
  to the gate.
- ~~`participant_events_integration` needs Kafka~~ — it never did. It captures through an in-process
  stub, but that stub was declared inside *another test file*, so the suite only passed when that file
  happened to load in the same run. Moved to `test/support`; passes alone, together, and in either
  order. A latent order-dependency the per-suite runner exposed.
- ~~~150 files fail `mix format`~~ — swept, and re-swept under CI's pinned 1.18.4.
