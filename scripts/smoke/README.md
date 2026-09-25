# Prod smoke harnesses

Read-mostly checks against `https://api.growblic.com`, driven exactly the way a client drives it
(OTP login → REST → socket). They exist so a contract can be verified in prod in one command, with
every status and body printed, instead of by hand on the box.

## Accounts

Only the **reviewer-allowlist** harness accounts — these are the only numbers that may be logged
into from a script, and the allowlist is what lets their fixed OTPs work without an SMS:

| | phone | OTP |
|---|---|---|
| A | `+15550199001` | `900001` |
| B | `+15550199002` | `900002` |

Never point these at any other number. If `POST /auth/otp/request` answers anything but 2xx, the
allowlist has changed — stop and say so; do not retry with a different account.

Access tokens are minted at run time and redacted to 6 characters in the output. **Nothing in these
files is a secret**; nothing minted by them may be pasted back in.

## Scripts

`sharing_smoke.mjs` — the `sharing_disabled` contract end to end: login both, create a DM and a
group, PATCH the setting on each, read it back as both members, the member-not-admin 403, the
forward refusals (`conversation.sharing_disabled`) and allowances, the two system rows, then reset
both to `false`. Leaves the conversations in place.

`user_updated_probe.mjs` — does an avatar PATCH by A produce `user_updated` on B's user topic? Joins
B's socket, does a REAL avatar upload as A (describe → PUT bytes → complete), PATCHes
`avatar_media_id`, and prints what B received. Observes the live socket — no server change needed.

`admin_health.mjs` — `GET /api/v1/admin/health` end to end, **local stack only** (the base URL must
be loopback; there is no override). Logs in as A, promotes A to root in the LOCAL postgres container
named by `LOCAL_DB_CONTAINER` (or expects you to have done it), and asserts `services[]` has the seven
entries with `notification.status == "up"` — true only when notification-service's Redis heartbeat is
live. Never point it at prod: making a reviewer account root anywhere but a throwaway stack is not
a thing a script should be able to do.

`socket_latency.mjs` — send→receive latency over the socket: A pushes 20 `message:create`s on the
A–B conversation channel while B's socket timestamps `message_created` on the same topic; then
turns encryption ON, sends 20 sealed envelopes (real libsodium boxes to both devices), and hands
the DM back with the two-party OFF. Prints p50/p95/max per leg plus the send ack. Needs
`libsodium-wrappers` from `apps/web/node_modules` (already installed there).

## Running

```bash
cd scripts/smoke
npm install ws --no-save        # user_updated_probe.mjs only; sharing_smoke.mjs needs nothing
node sharing_smoke.mjs
node user_updated_probe.mjs
node media_perf.mjs             # media pipeline timing (init/PUT/complete/send/presign/GET, plain + sealed, Range 206)
```

Node 20+. Each prints `step  METHOD path → status  body` per call and a one-line verdict at the end.
