# Chat Platform — Integration Guide

Embed real-time messaging into your application. This guide walks you from zero
to a working integration: registering an app, issuing keys, sending messages,
connecting end-users to the real-time socket, and verifying webhook deliveries.

The companion `openapi.yaml` is the precise, machine-readable reference for
every REST endpoint. This guide provides the narrative, the flows, and the code
you'll actually copy.

---

## Contents

1. [Core concepts](#1-core-concepts)
2. [Quickstart](#2-quickstart)
3. [Authentication](#3-authentication)
4. [Token exchange (connecting end-users)](#4-token-exchange-connecting-end-users)
5. [REST API](#5-rest-api)
6. [Real-time socket](#6-real-time-socket)
7. [Webhooks](#7-webhooks)
8. [Verifying webhook signatures](#8-verifying-webhook-signatures)
9. [Test vs live mode](#9-test-vs-live-mode)
10. [Rate limits & idempotency](#10-rate-limits--idempotency)
11. [Errors](#11-errors)
12. [Current limitations](#12-current-limitations)

---

## 1. Core concepts

**App (tenant).** Your integration lives inside an *app*. All data — users,
conversations, messages, webhooks — is isolated per app. A credential for one
app can never read, write, or join another app's data.

**Two kinds of caller.** This is the most important thing to understand:

| Caller | Uses | Credential |
|--------|------|-----------|
| **Your server** | REST API (send messages, create conversations, register webhooks) | Secret API key `sk_live_…` / `sk_test_…` |
| **Your end-user's client** (browser / mobile) | REST API + real-time socket, on behalf of one user | Short-lived end-user token (JWT) minted by your server |

> **Never put a secret key in a browser or mobile app.** It grants full access
> to your app. Instead, mint a short-lived end-user token on your server (§4)
> and hand *that* to the client.

**Base URL.** The API is served from your gateway host. Examples here use
`http://localhost:4000`. Replace with your production host. The API version is
in the path (`/v1`); there is no version header.

---

## 2. Quickstart

Five steps to your first message.

**1 — Register an app** (with your first-party session token):

```bash
curl -X POST http://localhost:4000/api/v1/apps \
  -H "Authorization: Bearer $SESSION_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"Acme"}'
# -> {"app_id":"51f5...","name":"Acme","mode":"live"}
```

**2 — Issue a live API key** for that app:

```bash
curl -X POST http://localhost:4000/api/v1/api-keys \
  -H "Authorization: Bearer $SESSION_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"server key","mode":"live","app_id":"51f5..."}'
# -> { ..., "key_prefix":"sk_live_AbCd1234", "api_key":"sk_live_AbCd1234Ef..." }
```

Save `api_key` now — it is shown **once**.

**3 — Create a conversation** (server-side, with the secret key):

```bash
curl -X POST http://localhost:4000/v1/conversations \
  -H "Authorization: Bearer sk_live_AbCd1234Ef..." \
  -H "Content-Type: application/json" \
  -d '{"type":"direct","participants":["user_8823","user_9910"]}'
# -> {"conversation_id":"c123...", "type":"direct", ...}
```

**4 — Send a message** (secret key names the sender):

```bash
curl -X POST http://localhost:4000/v1/conversations/c123.../messages \
  -H "Authorization: Bearer sk_live_AbCd1234Ef..." \
  -H "Content-Type: application/json" \
  -d '{"body":"Your order has shipped.","sender":"user_8823"}'
# -> {"message_id":"m456...", "sender_user_id":"...", "body":"Your order has shipped.", ...}
```

**5 — Register a webhook** to receive events. Use your **secret key** — the
endpoint is scoped to that key's app automatically, so deliveries fire for
*your* app's events:

```bash
curl -X POST http://localhost:4000/v1/webhooks/endpoints \
  -H "Authorization: Bearer $LIVE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://api.acme.com/hooks/chat","event_types":["message.created"]}'
# -> { ..., "signing_secret":"whsec_..." }   # save this — shown once
```

> The same endpoints are also available under `/api/v1/webhooks/endpoints` with
> your first-party OTP **session** (for a dashboard); pass an owned `app_id` to
> target a specific app. An **end-user JWT may not** manage webhooks (`403
> v1.app_only`) — only a secret key can.

Done. Your server can now drive conversations, and you'll receive signed
`message.created` deliveries. Next: connect your end-users in real time (§4, §6).

---

## 3. Authentication

Every `/v1` request needs an `Authorization: Bearer <token>` header. The token
is one of:

- a **secret API key** (`sk_live_…` / `sk_test_…`) — identifies your server as
  acting for the whole app; or
- an **end-user token** (JWT from §4) — identifies one specific end-user.

Any authentication failure returns **`401`** with an identical body regardless
of the reason (missing, malformed, revoked, expired) — there is no oracle that
distinguishes them:

```json
{"error":{"code":"v1.unauthorized","message":"Invalid or missing credentials","correlation_id":"..."}}
```

**Secret key format & storage.** A key is `sk_live_` (or `sk_test_`) followed by
random data. The platform stores only a SHA-256 hash plus a non-secret prefix
(the first 16 chars, e.g. `sk_live_AbCd1234`) for display. The full key is
shown once at creation and is unrecoverable — if you lose it, revoke it and
issue a new one.

**App management endpoints** (`/api/v1/apps`, `/api/v1/api-keys`,
`/api/v1/webhooks/endpoints`) are authenticated with your first-party **OTP
session token**, not an API key, and are not subject to the `/v1` rate limit.
Webhook endpoints are the exception: they can **also** be managed with a secret
key under **`/v1/webhooks/endpoints`** (the recommended path for a headless
integrator server — no session needed; the key's app scopes the endpoint).

---

## 4. Token exchange (connecting end-users)

To let an end-user's client send messages or connect to the socket, mint a
short-lived token **on your server** and pass it to the client. The client
never sees your secret key.

```bash
curl -X POST http://localhost:4000/v1/auth/token \
  -H "Authorization: Bearer sk_live_AbCd1234Ef..." \
  -H "Content-Type: application/json" \
  -d '{"end_user_id":"user_8823"}'
```

```json
{
  "token": "eyJhbGciOi...",
  "token_type": "app_user",
  "app_id": "51f5...",
  "mode": "live",
  "user_id": "2c12...",
  "expires_in_seconds": 3600
}
```

- `end_user_id` is *your* opaque id for the user. It is resolved-or-created in
  your app and maps to a stable internal `user_id`.
- The token is valid for `expires_in_seconds` (**3600 = 1 hour**). Mint a fresh
  one when it expires.
- **Only a secret key may call this.** Presenting an end-user token here returns
  `403 v1.app_only`.

Typical flow: your client asks your backend "give me a chat token"; your backend
calls `/v1/auth/token` with its secret key and returns the JWT to the client;
the client uses that JWT for REST calls and the socket.

> `display_name` is accepted by this endpoint but is **not currently persisted**
> — see [Current limitations](#12-current-limitations).

---

## 5. REST API

Full request/response schemas are in `openapi.yaml`. Key behaviors:

**Create conversation** — `POST /v1/conversations`
`type` is `"direct"` or `"group"`; `participants` are your external user ids.
For `direct`, creation is **idempotent per pair** — the same two users always
resolve to the same conversation, never a duplicate. `app_id` is always taken
from your credential; any `app_id` in the body is ignored.

**Get conversation** — `GET /v1/conversations/{id}`
Returns a *summary* shape (note: its fields differ from the create response —
it includes `app_id` and `status`; see both schemas in `openapi.yaml`). A
conversation in another app returns `404`, identical to a non-existent one.

**Send message** — `POST /v1/conversations/{id}/messages`
The `sender` field is **required when using a secret key** (your server states
which user is sending) and **ignored when using an end-user token** (the sender
is the token's user). Supports `Idempotency-Key` (§10).

**List messages** — `GET /v1/conversations/{id}/messages`
Newest first, default 50. `next_cursor` is currently always `null` (§12).

---

## 6. Real-time socket

The socket delivers live messages, typing indicators, read receipts, and
presence. It uses Phoenix Channels over WebSocket.

**Connect.**

```
ws://localhost:4000/socket/websocket?vsn=2.0.0&token=<end-user-JWT>
```

- The token is passed as a **query param**. The server reads the first present
  of: `authorization`, `access_token`, `token`. The value may be `Bearer <jwt>`
  or a bare `<jwt>`.
- **Use an end-user token (§4).** Secret keys are **not** accepted on the
  socket — this is deliberate, so a long-lived server secret is never exposed in
  a URL, proxy log, or browser history.
- A failed connection fails the WebSocket upgrade with **HTTP 403**.

**Topics.**

| Topic | Who may join |
|-------|--------------|
| `conversation:<conversation_id>` | Members of that conversation, in your app |
| `user:<user_id>` | Only that same user (identity-pinned) |
| `call:<call_id>` | Resolved to its conversation, then same rule as above |

Joining a topic your token isn't entitled to returns a `phx_reply` with
status `"error"` and a body such as:

```json
{"code":"realtime.forbidden","message":"Conversation join is forbidden"}
```

**Join reply (success)** on a conversation topic:

```json
{"topic":"conversation:c123","conversation_id":"c123","user_id":"u1","status":"joined"}
```

**Events you send** (client → server) on a conversation channel include:
`message:create`, `message:update`, `message:delete`, `reaction:set`,
`reaction:remove`, `typing:start`, `typing:stop`, `message_read`,
`message_delivered`.

**Events you receive** (server → client) include: `message_created`,
`message_updated`, `message_deleted`, `reaction_updated`, `typing_started`,
`typing_stopped`, `presence_state` (on join), `presence_updated` (carries
`typing: true|false`), and `receipt_updated` (carries
`receipt_type: "read"|"delivered"`).

> The socket protocol is not part of `openapi.yaml` (OpenAPI can't express
> WebSocket). The strings above are the reference.

---

## 7. Webhooks

Register a URL to receive server-to-server event deliveries for your app.

**Register** — `POST /api/v1/webhooks/endpoints` (session-authenticated):

```json
{"url":"https://api.acme.com/hooks/chat","event_types":["message.created"]}
```

The response includes a `signing_secret` (`whsec_…`) **shown once** — store it;
you need it to verify deliveries (§8). `event_types` is optional and filtered to
known types; omit it to receive all.

**Event types** (the complete set today):

| Event | `data` fields |
|-------|---------------|
| `message.created` | `message_id`, `conversation_id`, `sender_user_id`, `message_type`, `body`, `created_at` |
| `conversation.created` | `conversation_id`, `type`, `title`, `created_by`, `participant_user_ids` |

**What a delivery looks like.** We `POST` JSON to your URL with these headers:

| Header | Value |
|--------|-------|
| `content-type` | `application/json` |
| `x-webhook-signature` | `sha256=<hmac-sha256 hex, lowercase>` |
| `x-webhook-id` | the delivery (outbox row) id — unique per delivery |
| `x-webhook-event-id` | the **stable** event id — same across retries; **dedupe on this** |
| `x-webhook-event-type` | e.g. `message.created` |
| `x-webhook-timestamp` | unix seconds, as a string |

The body envelope:

```json
{
  "id": "<event_id, same as x-webhook-event-id>",
  "type": "message.created",
  "created_at": "2026-07-01 09:30:00+00",
  "data": { "message_id": "m456...", "conversation_id": "c123...", "sender_user_id": "u1", "message_type": "text", "body": "hi", "created_at": "2026-07-01T09:30:00Z" }
}
```

**Delivery semantics.**
- Events are enqueued in a durable outbox **in the same transaction** as the
  underlying write, so a rolled-back message never produces a webhook, and a
  committed one always does.
- Delivery is **at-least-once**: on non-2xx or timeout (5s), we retry with
  backoff, then dead-letter after a cap. Because retries reuse
  `x-webhook-event-id`, **make your handler idempotent** — dedupe on that id.
- Return a `2xx` quickly to acknowledge. Do heavy work asynchronously.

---

## 8. Verifying webhook signatures

**Always verify the signature before trusting a delivery.** Otherwise anyone who
learns your URL could POST forged events.

The signature is `HMAC-SHA256` of the **exact raw request body bytes**, keyed by
your endpoint's `signing_secret`, hex-encoded lowercase, prefixed `sha256=`.

> **Critical:** compute the HMAC over the **raw body bytes you received** — do
> not parse the JSON and re-serialize it. Key ordering after re-serialization is
> not guaranteed and will produce a different signature. Capture the raw body
> before any JSON middleware touches it. Use a **constant-time** comparison.

### Node.js (Express)

```js
const crypto = require("crypto");

// Capture the RAW body — do not use express.json() before this route,
// or configure it to stash the raw buffer:
app.post("/hooks/chat",
  express.raw({ type: "application/json" }),
  (req, res) => {
    const signingSecret = process.env.CHAT_WEBHOOK_SECRET; // whsec_...
    const raw = req.body;                    // Buffer of the exact bytes
    const header = req.get("x-webhook-signature") || "";

    const expected =
      "sha256=" +
      crypto.createHmac("sha256", signingSecret).update(raw).digest("hex");

    const a = Buffer.from(header);
    const b = Buffer.from(expected);
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) {
      return res.status(401).send("bad signature");
    }

    const event = JSON.parse(raw.toString("utf8"));
    // Dedupe on the stable event id:
    // if (alreadyProcessed(req.get("x-webhook-event-id"))) return res.sendStatus(200);
    // ... handle event.type / event.data ...
    res.sendStatus(200);
  });
```

### Python (Flask)

```python
import hmac, hashlib, os
from flask import request, abort

@app.post("/hooks/chat")
def chat_hook():
    signing_secret = os.environ["CHAT_WEBHOOK_SECRET"].encode()  # whsec_...
    raw = request.get_data()                     # exact raw bytes
    header = request.headers.get("x-webhook-signature", "")

    expected = "sha256=" + hmac.new(signing_secret, raw, hashlib.sha256).hexdigest()

    if not hmac.compare_digest(header, expected):  # constant-time
        abort(401)

    import json
    event = json.loads(raw)
    # Dedupe on request.headers["x-webhook-event-id"]
    # handle event["type"] / event["data"]
    return "", 200
```

### Go

```go
func verify(raw []byte, header, secret string) bool {
    mac := hmac.New(sha256.New, []byte(secret))
    mac.Write(raw)
    expected := "sha256=" + hex.EncodeToString(mac.Sum(nil))
    return hmac.Equal([]byte(header), []byte(expected))
}
```

---

## 9. Test vs live mode

Keys are prefixed `sk_test_` or `sk_live_`. A **test key resolves to a separate,
fully isolated app** (a "test twin") — so data you create with a test key is
invisible to your live key and vice-versa. Register a webhook with a test-mode
session/app to receive test deliveries only.

Everything in this guide works identically in both modes. Build against
`sk_test_`, then switch to `sk_live_` for production — no code change beyond the
key.

---

## 10. Rate limits & idempotency

**Rate limit.** `/v1` requests are limited per app in a fixed 60-second window
(default **60 requests/window**). Over the limit returns **`429`** with a
`Retry-After` header (seconds until the window resets):

```json
{"error":{"code":"v1.rate_limited","message":"Too many requests. Please try again later.","correlation_id":"..."}}
```

There are no `X-RateLimit-*` headers on success — only `Retry-After` on a 429.

**Idempotency.** On `POST /v1/conversations/{id}/messages`, send an
`Idempotency-Key` header. A retry with the same key — scoped to app +
conversation — returns the **original** message rather than sending a duplicate.
Use this to make network retries safe.

> Both the rate limiter and idempotency store are currently in-process
> (single-node) — see [Current limitations](#12-current-limitations).

---

## 11. Errors

All errors share one envelope:

```json
{"error":{"code":"<code>","message":"<human message>","correlation_id":"<id>"}}
```

Include the `correlation_id` when contacting support. Statuses used by `/v1`:

| Status | Code | Meaning |
|--------|------|---------|
| 400 | `v1.invalid_request` | Request body is invalid. |
| 401 | `v1.unauthorized` | Missing/invalid credentials (identical for all auth failures). |
| 403 | `v1.app_only` | Endpoint requires a secret key (an end-user token was used). |
| 404 | `v1.not_found` | Not found, or not in your app (cross-tenant is indistinguishable from missing). |
| 429 | `v1.rate_limited` | Rate limit exceeded; see `Retry-After`. |
| 503 | `v1.unavailable` | Temporary; retry. |

---

## 12. Current limitations

Known gaps to be aware of when integrating today:

- **Message list pagination.** `next_cursor` is always `null`; only the newest
  page (default 50) is returned.
- **No `app_id` on the message response.** It is tracked internally but not
  exposed in the message payload.
- **Rate limit & idempotency are single-node.** They use in-process storage, so
  limits and idempotency keys are not shared across multiple gateway replicas
  and are not persistent across restarts.
- **Webhook signing secret at rest.** Stored recoverably (it must be, to sign
  deliveries); encryption-at-rest is a planned hardening.
- **Calls.** The `call:<id>` topic and its tenant gate exist and are enforced,
  but there is no production call producer yet.

---

*Reference: see `openapi.yaml` for exact REST schemas. This guide is the
authoritative reference for the real-time socket and webhook delivery format.*
