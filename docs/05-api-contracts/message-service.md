# Message Service API Contract

## Purpose

Defines the initial public message API exposed through the API Gateway. Message
persistence can be routed through the ScyllaDB adapter boundary when enabled;
live Cassandra/Scylla driver execution remains behind the shared client
adapter.

## Common Rules

- Base path: `/api/v1/conversations/:conversation_id/messages`
- Content type: `application/json`
- Message access checks require real auth later.
- ScyllaDB will be the source of truth for message timeline, receipts, and reactions.
- Configure `MESSAGE_STORE_ADAPTER=scylla` only with an explicit
  `SharedInfra.Scylla.Client` adapter. The default shared client returns
  unavailable instead of making network calls.
- Future events include `message.created.v1`, `message.edited.v1`, `message.deleted.v1`, `message.delivered.v1`, `message.read.v1`, and `message.reaction_added.v1`.
- DB-backed receipt endpoints derive `user_id` from the authenticated session; clients must not send or control receipt user identity.

## Error Shape

```json
{
  "error": {
    "code": "message.invalid_request",
    "message": "Request body is invalid",
    "correlation_id": "corr_123"
  }
}
```

## Error Codes

| Code | HTTP | Meaning |
|---|---:|---|
| message.invalid_request | 400 | Missing or invalid fields |
| message.unauthorized | 401 | Missing or invalid access token |
| message.forbidden | 403 | User cannot access conversation or message |
| message.not_found | 404 | Message does not exist |
| message.rate_limited | 429 | Message rate limit exceeded |
| message.internal_error | 500 | Unexpected service failure |

## POST /api/v1/conversations/:conversation_id/messages

Sends a message to a conversation.

Text request:

```json
{
  "message_type": "text",
  "body": "Hello",
  "reply_to_message_id": null,
  "metadata": {}
}
```

Media request:

```json
{
  "message_type": "media",
  "media_id": "44444444-4444-4444-8444-444444444444",
  "caption": "Launch photo",
  "reply_to_message_id": null,
  "metadata": {}
}
```

Media messages require `media_id`. `caption` is optional and is copied into
`body` for preview-friendly responses in this boundary slice. Live MinIO object
existence verification is deferred to a later Media Service integration slice.

Response `201`:

```json
{
  "conversation_id": "conv_123",
  "message_id": "msg_placeholder",
  "sender_user_id": "user_placeholder",
  "message_type": "text",
  "body": "Hello",
  "status": "active",
  "created_at": "2026-06-17T10:15:00Z"
}
```

Media response `201`:

```json
{
  "conversation_id": "conv_123",
  "message_id": "msg_123",
  "sender_user_id": "user_123",
  "message_type": "media",
  "body": "Launch photo",
  "media_id": "44444444-4444-4444-8444-444444444444",
  "caption": "Launch photo",
  "status": "active",
  "metadata": {
    "media_id": "44444444-4444-4444-8444-444444444444",
    "caption": "Launch photo"
  },
  "created_at": "2026-06-17T10:15:00Z",
  "edited_at": null,
  "deleted_at": null
}
```

## GET /api/v1/conversations/:conversation_id/messages

Lists recent messages in a conversation.

Response `200`:

```json
{
  "conversation_id": "conv_123",
  "messages": [
    {
      "message_id": "msg_placeholder",
      "sender_user_id": "user_placeholder",
      "message_type": "text",
      "body": "Hello",
      "status": "active",
      "created_at": "2026-06-17T10:15:00Z"
    }
  ],
  "next_cursor": null
}
```

## PATCH /api/v1/conversations/:conversation_id/messages/:message_id

Edits a message.

Request:

```json
{
  "body": "Hello edited"
}
```

Response `200`:

```json
{
  "conversation_id": "conv_123",
  "message_id": "msg_123",
  "body": "Hello edited",
  "status": "edited",
  "edited_at": "2026-06-17T10:20:00Z"
}
```

## DELETE /api/v1/conversations/:conversation_id/messages/:message_id

Deletes a message.

Response `200`:

```json
{
  "conversation_id": "conv_123",
  "message_id": "msg_123",
  "status": "deleted",
  "deleted_at": "2026-06-17T10:25:00Z"
}
```

## POST /api/v1/conversations/:conversation_id/messages/:message_id/read

Marks a message as read by the current user.

Response `200`:

```json
{
  "conversation_id": "conv_123",
  "message_id": "msg_123",
  "user_id": "user_123",
  "read_at": "2026-06-17T10:30:00Z"
}
```

## POST /api/v1/conversations/:conversation_id/messages/:message_id/delivered

Marks a message as delivered to the current user/device.

Response `200`:

```json
{
  "conversation_id": "conv_123",
  "message_id": "msg_123",
  "user_id": "user_123",
  "delivered_at": "2026-06-17T10:30:00Z"
}
```

## Search (`GET /api/v1/search/messages`)

Cross-conversation body search, scoped to conversations the caller still participates in. BOTH
clients call it: web, and Android's GLOBAL search screen, which is REST-only against this endpoint
(the exway-android audit, slice-71 — recorded in DECISION_LOG [2026-08-02]'s correction; only
Android's in-chat search is local Room). An earlier revision claimed web was the only client; that
was the belief the audit corrected, and losing this endpoint breaks search on both clients.

**Since 2026-08-08 it is served from the `message_search` copy** (DECISION_LOG [2026-08-08]:
message text lives in Postgres as a non-authoritative, rebuildable, deletion-propagated search
copy), with results hydrated from the authoritative store so deleted content never renders. Same
contract as it always had: substring `ILIKE`, recency order, `page`/50 pagination, min query
length 2.

The degradation contract below is NOT history — it is the live behaviour whenever the search-index
consumer is off (`KAFKA_SEARCH_CONSUMER_ENABLED`, host `.env`): the endpoint answers

```json
{
  "error": {
    "code": "search.unavailable",
    "message": "Message search is temporarily unavailable",
    "correlation_id": "corr_123"
  }
}
```

with HTTP 503. **Never a silent empty result list** — an empty list is indistinguishable from "no
matches" and would hide the degradation from both users and monitoring. Web should hide the search
affordance on this code. (The 2026-08-01 "acceptable while no external users" regression window
this section used to describe was real from the flip until the index shipped, later the same day.)

## Forward depth

## View-once messages (115)

A view-once send is ordinary media whose blob the server stops serving once the recipient has opened
it. The flag is **message metadata, not a media purpose** — the same asset can be an ordinary
attachment in one message and view-once in another.

### Create

```
POST /api/v1/conversations/:id/messages
  { "message_type": "media",
    "media_id": "<uuid>",
    "view_once": true }
```

`view_once` is valid **only** on `message_type: "media"`. Anything else is
`422 message.view_once_invalid`:

| Type | Result | Why |
|---|---|---|
| `media` | ✅ accepted | `media_id` is required for this type, so there is always a blob to delete |
| `sealed` | ❌ 422 | `media_id` is forced null for sealed sends — the descriptor rides inside the ciphertext, so the server can never find the blob. **View-once in a secret chat is client-enforced**, and is refused here rather than accepted and silently unenforceable |
| `text` and all others | ❌ 422 | No blob |

Absent or `false` is always fine, and unrecognised values read as `false` — only an explicit truthy
`view_once` on a non-media type is refused.

**Broadcasts refuse it**: `422 broadcast.view_once_unsupported`. One `media_id` fans out to N
conversations, but the first open deletes the blob for everyone, so recipients 2..N would silently
lose a message they were told they had. The flag is refused rather than quietly stripped, because a
sender who believes they sent view-once and did not is the one failure this feature must never have.

**The `/v1` integrator surface ignores it.** `view_once` is not in its accepted fields, so an
integrator sending it gets an ordinary message — the flag is never set.

### Opening

```
POST /api/v1/conversations/:conversation_id/messages/:message_id/open
  (bearer session, no body)

200 { "message_id": "...", "opened_at": "2026-09-03T...Z", "status": "opened" }
403 message.sender_cannot_open
404 message.not_found
```

**Idempotent.** A replay returns the **original** `opened_at` and does not purge again, so a client
retrying a lost response cannot move the timestamp or trigger a second deletion.

**403 for the sender**: view-once is one-way. A sender able to re-read their own send would keep a
copy of what the recipient believes is gone.

**404 is opaque** for unknown, not-view-once, and not-your-conversation alike — a distinct "not
view-once" would confirm a message id exists to anyone probing.

Emits `view_once_opened` on `conversation:<id>`:

```json
{ "message_id": "...", "user_id": "...", "opened_at": "2026-09-03T...Z" }
```

### Enforcement

| Who | When | Download |
|---|---|---|
| Recipient | before their open | ✅ allowed (still subject to the ordinary media rules) |
| Recipient | after their open | ❌ 404 |
| Sender | any time after send | ❌ 404 |
| Anyone | 14 days unopened | ❌ 404, and the blob is purged |

Opening deletes the blob. View-once download URLs are signed for **120 seconds** rather than the
900-second default, because storage honours a signature rather than our authorization — deletion is
what actually closes that window, and the short TTL narrows it.

**A failed deletion never fails the open.** The receipt is the authoritative fact and commits
regardless; an undeleted blob is retried by an opportunistic sweep. A transient storage error must
not show an error on a message the server has already decided the user may read.

### What this does NOT do

View-once controls **server access to the blob**. It cannot prevent a screenshot, a screen recording,
or another phone pointed at the screen, and it should not be described to users as if it can. In
secret chats the server never sees the media id at all, so view-once there is entirely a client
promise — which is why the server refuses the flag on sealed sends rather than implying an
enforcement it cannot provide.

Misinformation friction, **not** a statistic. The signal is *distance from the origin*, not how many
copies exist.

```
POST /api/v1/conversations/:id/messages
  { …,
    "forwarded_from_message_id":      "<uuid>",   // the message being forwarded
    "forwarded_from_conversation_id": "<uuid>" }  // its conversation (needed to resolve the row)

message.metadata gains:
  "forward_depth": 3     // SERVER-SET, 1..5. Absent on an original message.
```

**Clients never write `forward_depth`.** Any value supplied in metadata is discarded and recomputed
from the source message row. A friction signal a client can reset to zero is worthless, and the
client most motivated to reset it is the one spreading the message.

**Display thresholds:** `>= 1` → "Forwarded". `>= 5` → "Forwarded many times". Capped at 5 so the
value stays a signal rather than a tracking number.

**Absent, not 0, on an original.** An original message is not "forwarded zero times"; clients should
not have to distinguish those.

**An untraceable source yields depth 1, not an error.** Unknown id, deleted source, or a conversation
the forwarder has since left — a forward we cannot trace is still a forward, and failing the send
would be far worse than a slightly low badge.

**It rides the MESSAGE, not the media.** Forwarding media re-uploads the bytes as a new asset with a
new `media_id`; the depth is resolved from the source *message*, so the chain survives that.

### HONEST LIMITATION: depth undercounts breadth

A message blasted directly to 100 chats is **depth 1 for every recipient**. Depth measures how FAR
content has travelled from its source, not how WIDELY it was sent. WhatsApp has the same property and
it is the right trade — the thing worth flagging is content that has moved far from where it started.
Do not present `forward_depth` as a reach or popularity number; it is not one.
