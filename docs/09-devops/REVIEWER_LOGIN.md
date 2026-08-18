# Play-Reviewer Test Login

A config-driven allowlist of phone numbers whose OTP is a **fixed code** and whose login **never
sends an SMS** — so Google Play reviewers can sign in to a working account. Off by default
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
