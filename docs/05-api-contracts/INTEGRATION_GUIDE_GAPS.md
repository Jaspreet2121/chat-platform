# INTEGRATION_GUIDE.md — gaps found by the conformance walk

Every place `INTEGRATION_GUIDE.md` and reality diverge, one line each: what the guide says, what
reality does, severity. The **instrument** is the executable onboarding walk in the SDK repo —
`packages/client-core/integration/onboarding-walk.integration.test.ts` (growblic-sdk `39441eb`) —
which walks the quickstart verbatim as "integrator #2": consumer session → app allocation → `sk_test_`
key (twin) → conversation → message → webhook → isolation and delivery-evidence assertions. This
report is the deliverable; the walk either clears these lines or extends them.

**Run status: the walk RAN against production on 2026-08-09 — FULL journey, 19/19** (growblic-sdk
`c3c1946`; operator-assisted phase 1 with a fresh remember-me session). It allocated
`walk-2026-08-09-9pnz6ttg` (`2c68d033-405e-4406-8396-0046a007a309`, twin
`0f365f37-af17-40f1-aedb-d426718bde5f`) and re-ran footprint-free via `WALK_APP_ID`. One instrument
fix between the two runs: the 404-indistinguishability compare now strips `correlation_id` (a
per-request id; isolation itself held on the first run too). Lines 1–2 were found by reading the
guide as an outsider during the walk's design review; line 3 by a live probe (2026-08-08), confirmed
at runtime (`status=pending attempts=1 last_error="HTTP 404"` in the delivery log); line 4 found
statically while building the walk and **pinned at runtime** (the twin log answered 403 on
production). One probe remains unwalked: step 6's other-live-app conversation (no
`WALK_FOREIGN_CONVERSATION_ID` supplied; the tenant-zero probe and the random-id floor both held).

Running it (operator-assisted; see the suite's header comment for the full minting steps):

```
# packages/client-core/.env.integration (gitignored)
WALK_SESSION_TOKEN=...        # 7-day remember_me session via the OTP flow — minted by a human; prod OTP is a real SMS
WALK_ALLOW_PROD=1             # explicit belt: without it the suite self-skips against *.growblic.com
WALK_APP_ID=...               # optional: reuse a prior walk app instead of allocating another
WALK_TENANT_ZERO_CONVERSATION_ID=...   # optional: real foreign ids for the step-6 isolation probes
WALK_FOREIGN_CONVERSATION_ID=...

pnpm vitest run --config vitest.integration.config.ts onboarding-walk
```

Without `WALK_SESSION_TOKEN` the walk degrades to the harness credential and reports a PARTIAL WALK —
step 10 names every step it could not walk. It is additive only: its mutations are POST
app/key/conversation/message/webhook inside the tenant it allocates; other tenants are only ever
asserted unreachable.

## Gaps

| # | Guide says | Reality | Severity |
|---|---|---|---|
| 1 | Step 1: "Register an app (with your first-party session token)" — `$SESSION_TOKEN` appears fully formed. | The guide never says how to obtain a session token. The OTP flow lives in the consumer app (`POST /api/v1/auth/otp/request` + `/verify`) and is documented nowhere an integrator is pointed at. An outsider following the guide verbatim is blocked at word one of step 1. | **Blocker** (for an unassisted outsider; the "done for you" note is the only escape hatch) |
| 2 | "Examples here use `http://localhost:4000`. Replace with your production host." | The production host is never named anywhere in the guide. An SDK user is rescued by the SDK's built-in default (`https://api.growblic.com`); a raw-REST integrator has nothing to replace localhost *with*. | Medium |
| 3 | Step 5 registers `https://api.acme.com/hooks/chat` — a receiver the integrator is assumed to already run. | There is no zero-setup URL an integrator can point a webhook at to see a **2xx** delivery. The platform's own public endpoint (`GET /health`) answers 404 to POST (probed 2026-08-08). The walk therefore asserts the evidence floor: the delivery **attempt** with its 404 status in the delivery log, not a 2xx. | Low–medium (DX: first-delivery gratification requires standing up a receiver) |
| 4 | §9: test-twin webhooks are registered and managed with the `sk_test_` key on `/v1` — presented as a complete test-mode story. | The **delivery log** (`GET /api/v1/webhooks/deliveries?app_id=…`) rides the owner console, and ownership is `app_owners` rows — which a test twin never has (`AppOwnerAuth` → `owns_app`; twins are "never owned" by design). So `app_id=<twin>` answers **403**: twin deliveries are dispatched but **unobservable by their integrator**. Statically verified while building the walk; step 8 pins the 403 at runtime and earns delivery evidence on the live app's endpoint instead. | **High** (an integrator debugging their test webhook has no window at all) |

## Observations (not gaps)

- The quickstart's own order sends the first message (step 4) before any webhook exists (step 5), so
  the quickstart's first message can never appear in a delivery log. This is documented behaviour —
  the "inert until you configure it" note says endpoint-less events are not enqueued — but an
  integrator checking their delivery log right after finishing the five steps may wonder where the
  message went. The walk sends a post-registration message to make the pipeline observable.
- The guide's step-4 response shows a `message_id` field. **Confirmed on the 2026-08-09 run**: the
  walk asserts the real key at runtime and emits a note if reality spells it differently — no note
  was emitted, so the send response carries `message_id` exactly as the guide shows.

## Coverage map (guide section → walk step)

| Guide | Walk step | Walked? |
|---|---|---|
| §2 step 1 — register an app | 1 (distinct `app_id`, not tenant-zero, owner row via `GET /api/v1/apps`) | **walked 2026-08-09** (`c3c1946`) |
| §2 step 2 — issue a key | 2 (`mode:"test"` → `sk_test_` prefix, once-only key, **twin app_id minted**), 2b (literal live key) | **walked 2026-08-09** |
| §2 step 3 — create a conversation | 3 (secret-key server actor) | **walked 2026-08-09** |
| §2 step 4 — send a message | 4 (REST send, key names the sender; `message_id` shape confirmed) | **walked 2026-08-09** |
| §2 step 5 — register a webhook | 5 (`/v1` + `sk_test_`, `whsec_` once, never on the list), 5b (the session-scoped `/api/v1` note, owned `app_id`) | **walked 2026-08-09** |
| §4 token exchange | 6/7 (every end-user token in the walk is minted via `POST /v1/auth/token`) | **walked 2026-08-09** |
| §6 socket | 4 (the other participant's SDK socket receives the sent message, same id) | **walked 2026-08-09** |
| §7–§8 webhook delivery + signatures | 8 (attempt + status in the delivery log — evidence floor held: `HTTP 404`, attempts=1; signature *verification* needs a real receiver: out of scope, see gap 3) | **walked 2026-08-09** (evidence floor) |
| §9 test vs live | 2 (twin mint), 7 (isolation both directions), 8 (twin delivery-log 403 — gap 4, pinned live) | **walked 2026-08-09** |
| tenant isolation (implicit contract) | 6 (foreign conversation ids are 404, same shape as nonexistent modulo `correlation_id`) | **partial 2026-08-09** — tenant-zero probe + random-id floor held; other-live-app probe awaits `WALK_FOREIGN_CONVERSATION_ID` |
| event pipeline health (not in the guide) | 9 (admin outbox summary: staged=0/pending=0 — zeros mean health) | **walked 2026-08-09** |

Maintenance: step 10 of the walk prints `conformance note (→ INTEGRATION_GUIDE_GAPS.md)` lines for
anything new it finds — fold them in here, and flip a coverage row to "walked (date, commit)" only on
a passing run. When a gap above is fixed in the guide or the platform, keep the line and mark it
resolved with the fixing commit: the report is a ledger, not a snapshot.
