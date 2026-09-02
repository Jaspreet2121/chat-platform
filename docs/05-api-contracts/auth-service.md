# Auth Service API Contract

## Purpose

Defines the initial public authentication API exposed through the API Gateway. This contract is a foundation only; production OTP delivery, token signing, and verification are not implemented yet.

## Common Rules

- Base path: `/api/v1/auth`
- Content type: `application/json`
- Tokens and OTPs must never be logged.
- Refresh tokens and OTPs must be stored hashed when persistence is implemented.
- Auth rate limits follow `docs/08-security/SECURITY_MODEL.md`.
- Access tokens currently use the Auth Service signed-envelope helper. Token
  TTL, refresh TTL, issuer, and audience are configurable; production JWT
  signing remains future work.

## Error Shape

```json
{
  "error": {
    "code": "auth.invalid_request",
    "message": "Request body is invalid",
    "correlation_id": "corr_123"
  }
}
```

## Error Codes

| Code | HTTP | Meaning |
|---|---:|---|
| auth.invalid_request | 400 | Missing or invalid fields |
| auth.unsupported_destination | 400 | Unsupported phone/email destination |
| auth.otp_invalid | 401 | OTP is wrong or expired |
| auth.token_invalid | 401 | Access or refresh token is invalid |
| auth.refresh_invalid | 401 | Refresh failed for an uncharacterised reason (unknown token, device_id mismatch, inactive user) |
| auth.refresh_expired | 401 | Refresh token expired — re-login, local data can be kept |
| auth.refresh_reused | 401 | Refresh token already rotated or revoked — treat as compromise |
| auth.session_revoked | 401 | Device session revoked or gone — treat as a sign-out |
| auth.session_invalid | 401 | Session token is missing, invalid, or revoked |
| auth.session_not_found | 404 | Session does not exist or was revoked |
| auth.rate_limited | 429 | Rate limit exceeded |
| rate_limit.exceeded | 429 | API Gateway route rate limit exceeded |
| auth.internal_error | 500 | Unexpected service failure |

## POST /api/v1/auth/otp/request

Requests an OTP for phone login.

Current backend behavior persists a hashed OTP in `verification_codes` when
database-backed OTP requests are enabled. The raw OTP is not returned in the API
response and no real SMS/email delivery is performed yet.

API Gateway rate limiting can protect this route when enabled. The current
boundary keys limits by client IP and normalized phone/email target. The
production adapter path can use Redis counters, while tests keep an in-memory
adapter so the normal suite remains Docker-free.

Request:

```json
{
  "phone_number": "+919999999999",
  "purpose": "login",
  "device": {
    "device_id": "ios-device-123",
    "platform": "ios",
    "device_name": "Jaspreet iPhone"
  }
}
```

Response `202`:

```json
{
  "otp_request_id": "otp_req_123",
  "delivery_method": "sms",
  "expires_in_seconds": 300,
  "retry_after_seconds": 60
}
```

## POST /api/v1/auth/otp/verify

Verifies an OTP and creates or resumes a device session.

Current backend behavior can verify a database-backed OTP when opt-in verify
persistence is enabled. It rejects expired or consumed verification codes,
creates or reuses a `users_auth` row, consumes the verification code, creates or
updates a `device_sessions` row, and stores only a hashed refresh token in
`refresh_tokens`. Explicit verification-code revocation requires a future schema
change because `verification_codes` does not yet have a revocation column.

Request:

```json
{
  "otp_request_id": "otp_req_123",
  "phone_number": "+919999999999",
  "otp_code": "123456",
  "device_id": "ios-device-123"
}
```

Response `200`:

```json
{
  "user_id": "user_placeholder",
  "session_id": "sess_placeholder",
  "access_token": "access_token_placeholder",
  "access_token_expires_in_seconds": 900,
  "refresh_token": "refresh_token_placeholder",
  "refresh_token_expires_in_seconds": 2592000
}
```

## POST /api/v1/auth/refresh

Rotates a refresh token and returns a new access token.

Current backend behavior can rotate refresh tokens when opt-in refresh
persistence is enabled. The submitted token is hashed before lookup. Successful
rotation revokes the old `refresh_tokens` row, creates a new row storing only the
new token hash, and updates the matching `device_sessions` record.

Request — **both fields are required**:

```json
{
  "refresh_token": "refresh_token_placeholder",
  "device_id": "ios-device-123"
}
```

`device_id` **must** be sent and **must** match the device the token was issued to. It is
not optional: an absent `device_id` compares as `nil` against the token's own value and is
rejected exactly like a mismatch, with no distinguishing error. It is checked against
`refresh_tokens.device_id`, not against the access token.

### Failure codes — all `401`, and they mean different things

The four codes exist so a client can tell a routine expiry from a possible compromise.
Before they were split, every refusal was `auth.refresh_invalid`, and a client facing that
ambiguity could only respond conservatively — one shipped client wiped all local data,
including E2EE keys, on what was an ordinary scheduled expiry.

| Code | Cause | What the client should do |
|---|---|---|
| `auth.refresh_expired` | The refresh token passed its `expires_at`. | **Re-login, and KEEP local data.** Nothing was compromised; the session simply aged out. Destroying local state here loses message history and E2EE keys for no security benefit. |
| `auth.refresh_reused` | The token was already rotated or revoked, or the device session has since rotated past it. | **Treat as a possible compromise.** Benign if a response was lost in flight, hostile if the token was replayed. Re-authenticate; clearing secrets is defensible. |
| `auth.session_revoked` | The device session is gone or explicitly revoked — a sign-out, "sign out everywhere else", or an admin action. | **Treat as a deliberate sign-out.** The session was taken away. Clear local state and return to login. |
| `auth.refresh_invalid` | Anything else: unknown token, `device_id` mismatch, inactive user, or an internal failure. | **Be conservative.** The server could not characterise the failure. |

The status is `401` for all four, so clients that key only off the HTTP status are unaffected
by the split. `POST /api/v1/auth/logout` reports every one of these as `auth.refresh_invalid`
— the distinction is about how to react to a failed *rotation*, and there is no such choice
when signing out.

Response `200`:

```json
{
  "access_token": "new_access_token_placeholder",
  "access_token_expires_in_seconds": 900,
  "refresh_token": "new_refresh_token_placeholder",
  "refresh_token_expires_in_seconds": 2592000
}
```

## POST /api/v1/auth/logout

Revokes the current device session.

Current backend behavior can revoke a refresh token and its associated device
session when opt-in logout persistence is enabled. The submitted refresh token
is hashed before lookup. Missing request fields return `auth.invalid_request`;
invalid or already-revoked refresh tokens return `auth.refresh_invalid`.
Successful logout marks the matching device session revoked, which invalidates
existing access-token session lookups for that device session. Already-revoked
tokens are rejected rather than treated as idempotent success.

Request:

```json
{
  "refresh_token": "refresh_token_placeholder",
  "device_id": "ios-device-123"
}
```

Response `204`:

No response body.

## GET /api/v1/auth/session

Returns the current authenticated session. Requires `Authorization: Bearer <access_token>`.

Current backend behavior can validate the existing signed-envelope access-token
helper format when opt-in session persistence is enabled. Missing, malformed,
expired, or invalid Bearer tokens, revoked device sessions, missing users, and
token/session mismatches return `auth.session_invalid`. Issuer and audience
claims are validated when present. This is not production JWT signing or JWT
blacklist behavior.

Response `200`:

```json
{
  "session_id": "sess_placeholder",
  "user_id": "user_placeholder",
  "device_id": "device_placeholder",
  "platform": "ios",
  "issued_at": "2026-06-16T18:00:00Z",
  "expires_at": "2026-06-16T18:15:00Z"
}
```
