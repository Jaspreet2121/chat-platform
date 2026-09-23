# Reviewer / test-login allowlist

A config-driven allowlist of phone numbers whose OTP is a **fixed code** and whose login **never
sends an SMS** — so store reviewers can sign in to a working account, and so we have test logins that
spend no SMS credit and need no real handset. Built for Play review; Apple App Review and our own
test accounts now ride the same mechanism. Off by default
everywhere; nothing about an allowlisted session is special once minted (normal tenant-zero
session, normal TTLs, normal rate limits).

## How it works

- `REVIEWER_TEST_LOGINS` (env, **auth service only** — the gateway proxies OTP untouched):
  comma-separated `<E.164 phone>:<6-digit code>`, e.g. `+15550100001:731945`. Empty/unset = OFF.
- Parsed once at boot (`AuthService.ReviewerLogins.load/0`); only the **count** is logged.
- `request-otp` for an allowlisted number behaves byte-identically to a normal request (same
  response, same rate limits, a real verification-code row) — it only skips the SMS provider, so
  the allowlist is not an enumeration oracle and spends no credit.
- `verify-otp` accepts the configured code (constant-time compare) for the `login` purpose;
  attempts are still charged, expiry/exhaustion still apply; a wrong code fails normally.
- Every successful reviewer login logs `reviewer test login verified for …NNNN` (phone masked).

## Setup (once)

1. Add to `/home/ubuntu/chat-platform/.env` (pick a strong random 6-digit code; the number below
   must match the seed's reviewer phone):

       REVIEWER_TEST_LOGINS=+15550100001:<code>

2. Seed the reviewer account, its support peer, their conversation, and one call-history row
   (idempotent; deliberately NOT in the migration stream — it is prod data, not schema):

       docker compose -f docker-compose.prod.yml exec -T postgres \
         psql -U chat_user -d chat_platform -f - < infra/docker/postgres/seed/reviewer_seed.sql

3. Send the welcome message ONCE through the real API (messages live in ScyllaDB — SQL cannot seed
   them). Temporarily allowlist the support number too
   (`REVIEWER_TEST_LOGINS=+15550100001:<code>,+15550100002:<tempcode>`, `up -d auth`), then:

       # login as Skifi Support via the test OTP (request → verify with <tempcode>), then:
       curl -s -X POST https://api.growblic.com/api/v1/conversations/aaaaaaaa-0000-4000-8000-000000000003/messages \
         -H "Authorization: Bearer $SUPPORT_SESSION" -H "Content-Type: application/json" \
         -d '{"body":"Welcome to Skifi! This is a demo conversation — try sending a message or starting a call."}'

   Then REMOVE the support entry from the env and `up -d auth` again (step 4). The support
   account keeps no standing credential.

4. Apply env changes:

       docker compose -f docker-compose.prod.yml --profile calls --profile kafka up -d auth

## The allowlist today

Five entries. The codes for the test numbers are deliberately unguessable-free — these accounts hold
no real data and exist only to be signed into — while the **seeded Play-reviewer** code is a real
secret and is not written down here.

| Number | Code | Purpose |
|---|---|---|
| `+15550100001` | *(secret, in `.env`)* | The seeded **Play Reviewer** account — @playreviewer, the Skifi Support chat, the call-history row |
| `+15550199001` | `900001` | Test account **A** — the one end of a two-account test |
| `+15550199002` | `900002` | Test account **B** — the other end |
| `+15550199003` | `900003` | **App Review only** (Apple). Reserved for App Store review; do not use it for day-to-day testing, so its state stays predictable when a reviewer signs in |
| `+15550199004` | `900004` | **Account-deletion testing.** Reusable — see below |

### Adding the two new entries

`REVIEWER_TEST_LOGINS` is a **single comma-separated line**, so a new entry is appended to the
existing value, never written on a second line. The format the parser accepts is
`<E.164 phone>:<6 digits>`, comma-separated; malformed entries are silently dropped (counted in the
boot log, never printed), so a typo disables that one login with no other symptom.

> **Read the current value before you replace it.** The seeded Play-reviewer entry carries a code
> that only `.env` has. Overwriting the line with one that omits it **breaks the Play reviewer
> login** — and the only symptom is that their OTP stops working.

```bash
cd ~/chat-platform
grep '^REVIEWER_TEST_LOGINS=' .env
```

Append the two, preserving whatever is already there:

```bash
cp .env ~/.env.bak-$(date +%F)
sed -i 's/^REVIEWER_TEST_LOGINS=\(.*\)$/REVIEWER_TEST_LOGINS=\1,+15550199003:900003,+15550199004:900004/' .env
grep '^REVIEWER_TEST_LOGINS=' .env
```

The result must read as one line, five entries, no spaces:

```
REVIEWER_TEST_LOGINS=+15550100001:<existing secret>,+15550199001:900001,+15550199002:900002,+15550199003:900003,+15550199004:900004
```

### Applying it — one command, `auth` only

```bash
docker compose -f docker-compose.prod.yml --profile calls --profile kafka up -d auth
```

**`up -d`, not `restart`.** `restart` reuses the existing container with its existing environment and
would silently do nothing; `up -d` sees the changed env, recreates the container, and `load/0` re-reads
it at boot.

**And `auth` alone is correct here**, despite the standing rule that the gateway ships with-or-before
auth. That rule exists because auth returning *new error atoms* needs a gateway that has them — it is
about shipping new **code**. This changes only an environment variable; the auth image is unchanged, so
there is nothing for the gateway to fail to recognise.

**Shows it worked** — the count, which is all that is ever logged:

```bash
docker compose -f docker-compose.prod.yml logs --tail=50 auth | grep -i "reviewer test logins"
```

Expect `reviewer test logins: 5 configured`. A **lower number means entries were dropped as
malformed** — check for a space after a comma, a missing `+`, or a code that is not exactly six
digits. A `… N malformed entries DROPPED` warning on the same line names how many.

Then prove one end to end, on a new number only:

```bash
API=https://api.growblic.com
REQ=$(curl -sS -X POST $API/api/v1/auth/otp/request -H 'content-type: application/json' \
  -d '{"phone_number":"+15550199003","purpose":"login"}')
OTP_ID=$(echo "$REQ" | python3 -c 'import json,sys;print(json.load(sys.stdin)["otp_request_id"])')
curl -sS -X POST $API/api/v1/auth/otp/verify -H 'content-type: application/json' \
  -d "{\"otp_request_id\":\"$OTP_ID\",\"phone_number\":\"+15550199003\",\"otp_code\":\"900003\",\"device_id\":\"allowlist-check\"}" \
  | head -c 200; echo
```

Expect an `access_token`. `auth.otp_invalid` means that entry did not parse.

## Why `+15550199004` is reusable for deletion testing

Self-serve deletion (130) writes a **tombstone**: the `users_auth` row survives with its id, and the
identity columns are scrubbed — `phone_number = NULL`, `email = NULL`, `password_hash = NULL`,
`external_id = NULL` (`AuthService.AccountDeletion`). The unique index on the phone is **partial**, on
`phone_number IS NOT NULL`, so a NULL frees the number immediately and the next OTP request for it
auto-creates a fresh account. Deleting and re-registering the same number is therefore repeatable with
no cleanup and no DB surgery.

Two things that are **not** reset, and will bite on the second run:

* **The username is held for 30 days.** Deletion inserts into `username_holds` with
  `held_until = now() + interval '30 days'`, so the account's @handle cannot be taken again — not even
  by you, re-registering the same number. Use a **different username each run**, or expect the claim to
  be refused. The hold exists to close the vacated-handle impersonation vector, so do not clear it to
  make testing easier.
* **Messages other people received are theirs and survive.** That is the designed behaviour, not
  leakage: if `+15550199004` had written to a test peer, those rows stay in the peer's history with the
  now-tombstoned sender id.

Deletion requires re-auth with the account's own registered phone number, so the delete call must
present `+15550199004` — a valid session alone is not enough.

> **Still: never run deletion against `+15550100001`, `…199001`, `…199002` or `…199003`.**
> `…199004` exists precisely so the others keep their state. `…199003` in particular is reserved for
> App Review and should look the same every time a reviewer opens it.

## Rotating the code

Change the code in `.env`, then `docker compose -f docker-compose.prod.yml --profile calls --profile kafka up -d auth`.
(Boot-parsed; no rebuild needed.) To disable entirely, set it empty.

## What reviewers see

Login with the allowlisted number + code lands in the seeded account: display name
**Play Reviewer** (@playreviewer), one chat with **Skifi Support** containing the welcome message,
and one answered voice call in the Calls tab. Both accounts are tenant-zero rows — app-scoped
search/lookup means no other tenant can ever see them; there is no public "suggested users"
surface in the product (verified 2026-08-18).

## Caveats

- The seed's phone numbers and the env MUST agree — the OTP path finds users by phone, and an
  unknown number would auto-create a fresh empty account instead of the seeded one.
- The allowlisted account is otherwise a normal user (it can link devices via QR, place calls,
  etc.). That is deliberate: reviewers must be able to exercise the real product.
