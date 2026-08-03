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

## Search (`GET /api/v1/search/messages`) — and its planned degradation

Cross-conversation body search, scoped to conversations the caller still participates in. Today it is
served by a Postgres `ILIKE` over the caller's conversations (web is its only client; Android searches
its local Room store).

**AT THE SCYLLA FLIP THIS ENDPOINT STOPS WORKING** — deliberately, not silently. Message bodies leave
Postgres and no honest Scylla answer exists (no trigram/body index over a participant join). From the
flip onward the endpoint answers:

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
affordance on this code.

This is a recorded product regression with an expiry condition (DECISION_LOG 2026-08-01): acceptable
only while there are no external users; if external users exist before the flip, a rebuildable
non-authoritative Postgres search index (tsvector, derivable from Scylla) must ship first.

## Forward depth

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
