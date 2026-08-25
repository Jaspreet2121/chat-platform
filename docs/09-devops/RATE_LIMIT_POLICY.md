# Rate limit policy

Every rate limit in this system, its number, its window, its key, its fail direction, and **why**.

This file exists because the limits grew one slice at a time and were each decided in isolation. An
audit of all 163 routes found the result: seven limiters, an inconsistent fail split, one limiter that
had never been switched on in production, and an unlimited endpoint that was an account-takeover path.
**If you add an endpoint, give it a limit from this table by default — not by accident later.**

## The rule

> **Fail CLOSED when the limiter IS the security control. Fail OPEN when losing the request hurts
> more than skipping the limit.**

Applied honestly, that means contacts sync (an enumeration oracle) and OTP verify (brute force) reject
on a limiter outage, while message send and reports let the request through. It is not a preference
for safety in the abstract — failing closed on message send would take the product down every time
Redis blipped, and would protect nothing, because authorization is a separate control that keeps
working.

## The response contract

A client can only handle throttling uniformly if the server is uniform. It is, in three shapes:

| Situation | Status | Body | Header |
|---|---|---|---|
| Over the limit | **429** | `{error: {code, message, correlation_id}}` | `Retry-After: <seconds>` |
| Limiter outage, fail-closed | **503** | same envelope, `*.unavailable` / `*.limiter_unavailable` | `Retry-After: 30` |
| Limiter outage, fail-open | (request proceeds) | — | — |

The realtime socket is deliberately different, because it is not HTTP: a throttled **write** gets
`{:error, %{reason: "rate_limited", retry_after: n}}` and the socket stays connected; a throttled
**ephemeral** (typing, receipts) is dropped silently, because an error reply for a dropped typing
event is pure noise.

## The limits

| Endpoint / surface | Limit | Window | Key | Fail | Why this number |
|---|---|---|---|---|---|
| `POST /auth/otp/request` | 3 | 60s | (client IP, phone) | **CLOSED** | Every request costs an SMS. Bounds spend and victim bombing, and makes fresh `otp_request_id`s expensive — which is what stops the verify cap being bypassed. |
| `POST /auth/otp/verify` | 20 | 300s | (client IP, phone) | **CLOSED** | Outer bound on OTP brute force. ~4 codes' worth of fumbling; unreachable by a human. |
| OTP verify attempts | 5 | per code | `otp_request_id` | **CLOSED** | The primary brute-force defence. On exhaustion the code is **burned** (`consumed_at`), so only a fresh request produces a working code. |
| `POST /conversations/:id/messages` | 60 | 60s | user | OPEN | Fan-out ×N + Scylla + Postgres + webhook + push per send. Matches the socket's write bucket so the limit is not bypassable by transport. |
| Socket `write` (send/edit/delete/reaction/call control) | 60 | 60s | user, and app ×100 | OPEN | `RT_WRITE_LIMIT`. |
| Socket `join` | 30 | 60s | user, and app ×100 | OPEN | `RT_JOIN_LIMIT`. |
| Socket `ephemeral` (typing, receipts, presence) | 300 | 60s | user, and app ×100 | OPEN | `RT_EPHEMERAL_LIMIT`. Dropped silently over the limit. |
| Socket concurrent connections | 5/user, 1000/app | — | user, app | OPEN | `RT_MAX_SOCKETS_PER_USER`. |
| `POST /media/uploads` | 60 / **500** | 60s / **86400s** | user | OPEN | Two windows. The DAILY one bounds accumulation; the per-minute one stops a runaway client spending it in seconds. A multi-image send creates one upload per image and the batch cap is **10** (`MediaConstraints.MAX_BATCH_ITEMS`, exway-android `core/media/MediaConstraints.kt`), so 60/min clears **six full batches** — comfortably above real usage. Daily is checked FIRST so its Retry-After is what a client sees when both trip. |
| `POST /invite-links/:code/join` | 10 | 3600s | user | **CLOSED** | Stops one account joining every link it finds. |
| `POST /invite-links/:code/join` | **60** | 3600s | **invite code** (per-resource) | **CLOSED** | Stops MANY accounts draining ONE leaked link, which the per-user limit cannot see. Generous on purpose: a viral group and an attack look identical from here. |
| `POST /contacts/sync` | 10 | 3600s | user | **CLOSED** | The enumeration oracle. 10 × 2000 numbers = 20k/hour/account. The limiter *is* the control. |
| `POST /broadcasts/:id/send` | 20 | 3600s | user | **CLOSED** | The spam amplifier — 20 sends × 256 recipients = 5,120 messages/hour. A limiter outage must not open that gate. |
| `POST /reports` | 5 | 3600s | user | OPEN | A legitimate safety report must not be lost to a Redis blip. |
| `GET /usernames/:u/availability` | 30 | 3600s | user | OPEN | Namespace prober. Availability is advisory UX, not a gate. |
| `POST/PATCH/DELETE/PUT /quick-replies*` | 30 | 60s | user | OPEN | Quick-reply writes (100) — user data, not an oracle; a Redis blip must not block saving a reply. Reads unlimited. |
| `GET /users/search` | 30 | 60s | user | **CLOSED** | The name-substring directory search (098) — a wider enumeration oracle than by-phone (one query returns up to 50 accounts). 30/min is generous for a human typing a name; the limiter *is* the control, so an outage rejects (contacts-sync precedent). |
| `POST /nearby/discover` | 6 | 60s | user | **CLOSED** | Proximity discovery returns up to 30 identity cards. 6/min (audit 2026-08-26; was 30) starves movement-based trilateration alongside per-pair bucket pinning, and a human refreshing a modal never reaches it. |
| `POST /nearby/requests` | 10 | 60s | user | **CLOSED** | Bounds unsolicited connection requests. A limiter outage must not turn a proximity surface into an unbounded spam path. |
| `POST /link/qr` | 10 | 60s | client IP | **CLOSED** | QR link mint (099) — unauthenticated and writes server state per call. 10/min covers every legitimate retry of a 60s-TTL code; an outage rejects (linking is optional, state-writing must not open up). |
| `GET /link/qr/:id/wait` | 30 | 60s | client IP | OPEN | The creating browser's long-poll (≤25s each, ~2/min legitimate). The poll_token is the security control, not this limiter — it is load protection, so it fails open. |
| `POST /link/approve` | 5 | 60s | user | **CLOSED** | The phone-side approval (099) — the security-sensitive step. 5/min is generous for a human scanning QRs; an outage rejects (a link the phone can't approve simply expires in 60s). |
| `/v1/*` (integrator API) | 3000 (`V1_RATE_LIMIT`) | 60s | **app_id** | OPEN | Per-tenant ceiling across all 28 `/v1` routes. |

`API_RATE_LIMITING_ENABLED` gates **only** the two pre-session auth limiters. Everything else is
always on. Production sets it `true`; it shipped unset (i.e. off) for the entire life of the OTP
request limiter, which is the defect that made this audit worth doing.

## Backlog — endpoints that still have no limit

Ranked by risk. These are **documented, not built**: that is what makes them a backlog rather than an
oversight. Numbers are the audit's recommendation, not settled fact.

| Endpoint | Abuse | Suggested | Fail |
|---|---|---|---|
| `POST /status` | Media storage + fan-out to every contact | 10/hour per user | open |
| `POST /conversations` | Unbounded rows; DM-spamming strangers | 20/hour per user | open |
| `POST /auth/refresh` | Token grinding; a DB hit per call | 60/hour per token family | open |
| `vote` / `reactions` / `read` / `delivered` | Cheap each, real in a tight loop; reactions broadcast | one shared 300/min "cheap writes" bucket | open |
| `PATCH /users/me`, `/privacy`, email PATCH | Churn; the email PATCH writes across services | 30/hour per user | open |
| `GET /users/by-phone`, `/by-username/:u` | Single-shot enumeration — the oracle contacts sync closes | 60/hour per user | closed |

## The per-resource key shape

Most limits key on the ACTOR. That axis is blind to many well-behaved actors converging on one
object — 500 accounts draining one leaked invite code are each inside their own budget, and the code
is drained anyway. `SharedInfra.ResourceLimit` is the other axis: the budget belongs to the resource,
and every actor touching it spends from the same pot.

    res:<resource_type>:<resource_id>:<action>

The `res:` prefix is load-bearing. Actor-keyed limits are `<action>:<subject_id>`, so without a
separate namespace a resource id and a user id could collide in one keyspace — and since both are
opaque strings here, the collision would be **silent**, surfacing as one user mysteriously consuming
a group's join budget. `<action>` is last so one resource can carry several independent budgets
without sharing a counter.

**Use it alongside a per-actor limit, not instead of one**, and check the per-actor limit FIRST: it
is the cheaper signal, and it bounds how much of a resource's budget any single caller can burn.
That last part matters because the resource is charged before the outcome is known — an
already-a-member re-join still spends a unit. Charging only on success would need a peek-then-commit
that the INCR-based limiter does not offer; the per-actor limit is what makes the residual
acceptable.

**Pass `fail_open` explicitly** — the module has no default. A per-resource limit is usually the
security control for its endpoint, but "usually" is not "always", and the trade has to be answered
where it is visible.

**What happens at the cap is a design decision, not a detail.** For invite joins the link stays alive
and the joiner gets a 429; the window drains on its own. Putting the link *dormant* until the owner
resets it was rejected: it hands anyone who can see a link the power to permanently disable it,
turning the limiter into a griefing tool aimed at the owner. Prefer the self-healing option whenever
a legitimate spike and an attack are indistinguishable — which, for anything per-resource, they
usually are. `reset_link` remains the owner's escalation when a code has genuinely leaked.

## Named defects and follow-ups

**Per-IP keying behind the proxy — fixed for the auth plug, verify before reusing.**
`conn.remote_ip` is Caddy's container bridge address for every request, identical for all callers.
Any per-IP limit that reads it is **decorative**. `ApiGatewayWeb.Plugs.RateLimit` now resolves the
client from `X-Forwarded-For`, taking the **last** entry — Caddy appends the address it observed, so
the rightmost value is the one a client cannot forge (`Plug.RewriteOn` takes the leftmost, which is
spoofable). This is sound only because there is exactly **one** trusted proxy and the gateway port is
not published. **If either changes, or if you add a per-IP limit anywhere else, revisit this first.**

**Media uploads are capped by OBJECT COUNT, not bytes — the disk is still not tightly defended.**
At the 100 MB per-object cap, a full daily budget is ~50 GB per account. 500/day turns "unbounded"
into "bounded" and stops runaway clients, which is worth having, but it is not disk safety. The
honest fix is a **byte quota charged at complete-time against the VERIFIED size** — create-time
`size_bytes` is client-declared and advisory, and `Media.verify_uploaded_size/1` already HEADs the
object for its real length, so the number needed is already being computed. Note it cannot prevent
the bytes landing (the PUT has already happened); it bounds accumulation and lets the account be cut
off. Pair it with MinIO capacity alerting.

**Redis connection-per-check — pooling follow-up.**
`SharedInfra.RateLimiter.RedisAdapter` opens and closes a fresh TCP connection on **every** check. At
10/hour on contacts sync that is nothing. On message send it is a connect + teardown **per message**,
and it gets worse with every limiter added to a hot path. Whoever adds the next hot-path limit should
pool the connection first rather than paying this again.

**`otp_request_id` is handed to the attacker — worth reshaping, not yet done.**
`POST /auth/otp/request` returns `otp_request_id` in its response, so anyone can request a code for a
phone they do not own and receive the handle needed to attack it; the victim just sees an SMS they
ignore. The attempts cap and the verify limit now make that handle far less useful, but they bound an
attack that a better shape would not offer at all.

**The better shape is to key verify on (phone + code) and keep the id server-side** — resolve the
active code with `VerificationCodes.find_active_code/3`, which already exists. Then possession of the
SMS is the only way in, and there is no per-request handle to hand out. It is not built here because
it is a client change as well as a server one (both clients send `otp_request_id` today), and it needs
a deliberate answer for concurrent outstanding codes for one phone. Recommended for the next auth
slice.

**Android outbox 429 behaviour is UNVERIFIED.** The Android client is not in this repo, so its retry
behaviour against the new send limit could not be checked. **Required before the send limit reaches
users:** an outbox that retries a 429 immediately without honouring `Retry-After` turns a throttle
into a hot loop; one that treats 429 as permanent silently drops queued messages. The web client was
checked and is fine — it preserves the draft and surfaces the server's message.

**Fixed windows burst at the boundary.** Every limiter here is a fixed-window `INCR`/`EXPIRE`, so up
to 2× the limit can pass across a window edge. Accepted everywhere: these are abuse guards, not exact
quotas, and the concurrency caps bound the rest.
