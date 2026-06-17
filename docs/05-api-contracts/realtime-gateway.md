# Realtime Gateway API Contract

## Purpose

Defines the initial Phoenix Channels contract exposed by the API Gateway. This is skeleton-first: production JWT authentication, cluster-wide Redis-backed Presence, Kafka consumption, and Kafka publishing are future work.

## Connection

WebSocket endpoint:

```txt
/socket
```

During placeholder mode, the socket accepts optional `user_id` and `device_id` params and assigns placeholders when absent.

When realtime socket auth persistence is enabled, clients must pass `authorization`, `access_token`, or `token` params. The gateway validates through the Auth Service session boundary and assigns `user_id` from the session.

## Topics

| Topic | Purpose |
|---|---|
| `conversation:{conversation_id}` | Conversation-level typing and receipt events |
| `user:{user_id}` | Per-user delivery, notification, and presence fanout |
| `call:{call_id}` | Call signaling session events |

When Conversation Service persistence is disabled, join authorization remains placeholder-only. When Conversation Service persistence is enabled, `conversation:{conversation_id}` joins require a socket `user_id` and are authorized through the Conversation Service conversation detail boundary. Tenant access and block status remain future work.

On successful `conversation:{conversation_id}` join, the gateway tracks the socket in Phoenix Presence when `user_id` is available and pushes the current `presence_state`.

Presence metadata:

```json
{
  "user_id": "user_123",
  "online_at": "2026-06-17T10:30:00Z"
}
```

## Client Events

### typing_started

Topic: `conversation:{conversation_id}`

Legacy placeholder event. Prefer `typing:start` for new clients.

```json
{
  "message_id": null
}
```

### typing_stopped

Topic: `conversation:{conversation_id}`

Legacy placeholder event. Prefer `typing:stop` for new clients.

```json
{}
```

### typing:start

Topic: `conversation:{conversation_id}`

Broadcasts `typing_started` to other subscribers. The user id is derived from the socket session.

```json
{}
```

Reply:

```json
{
  "event": "typing_started",
  "conversation_id": "conv_123",
  "user_id": "user_123",
  "occurred_at": "2026-06-17T10:30:00Z"
}
```

### typing:stop

Topic: `conversation:{conversation_id}`

Broadcasts `typing_stopped` to other subscribers. The user id is derived from the socket session.

```json
{}
```

Reply:

```json
{
  "event": "typing_stopped",
  "conversation_id": "conv_123",
  "user_id": "user_123",
  "occurred_at": "2026-06-17T10:30:05Z"
}
```

### message_read

Topic: `conversation:{conversation_id}`

```json
{
  "message_id": "msg_123"
}
```

### message_delivered

Topic: `conversation:{conversation_id}`

```json
{
  "message_id": "msg_123"
}
```

### message:create

Topic: `conversation:{conversation_id}`

Creates a message through the Message Service boundary. The sender is always derived from the socket session.

```json
{
  "message_type": "text",
  "body": "Hello"
}
```

Media payloads are also accepted:

```json
{
  "message_type": "media",
  "media_id": "44444444-4444-4444-8444-444444444444",
  "caption": "Launch photo"
}
```

Successful media replies and `message_created` broadcasts include `media_id`,
optional `caption`, and `metadata.media_id` (plus `metadata.object_key`/`filename`/
`content_type`/`size_bytes` when the client supplies them).

The web client pushes `message:create` for BOTH text and media creation whenever the
conversation socket is connected (HTTP `POST .../messages` is the fallback when it is
not). The sender inserts its new message from this reply; other clients receive it live
via the `message_created` broadcast (the sender is excluded by `broadcast_from`).

### message:update

Topic: `conversation:{conversation_id}`

Edits a message body through the Message Service boundary. The actor is derived
from the socket session. Requires `message_id` and a non-empty `body`. Only the
original sender may edit; a non-author receives `realtime.forbidden`. On success,
broadcasts `message_updated` to other subscribers and replies to the sender.

```json
{
  "message_id": "msg_123",
  "body": "Edited text"
}
```

Reply / `message_updated` broadcast:

```json
{
  "conversation_id": "conv_123",
  "message_id": "msg_123",
  "body": "Edited text",
  "status": "edited",
  "edited_at": "2026-06-18T10:30:00Z"
}
```

### message:delete

Topic: `conversation:{conversation_id}`

Soft-deletes a message through the Message Service boundary. The actor is derived
from the socket session. Requires `message_id`. Only the original sender may delete;
a non-author receives `realtime.forbidden`. On success, broadcasts `message_deleted`
to other subscribers and replies to the sender.

```json
{
  "message_id": "msg_123"
}
```

Reply / `message_deleted` broadcast:

```json
{
  "conversation_id": "conv_123",
  "message_id": "msg_123",
  "deleted": true,
  "status": "deleted",
  "deleted_at": "2026-06-18T10:31:00Z"
}
```

### call_signal

Topic: `call:{call_id}`

```json
{
  "type": "offer",
  "sdp": "placeholder"
}
```

## Server Events

| Event | Topic | Purpose |
|---|---|---|
| `message_created` | `conversation:{conversation_id}` | New message fanout |
| `message_updated` | `conversation:{conversation_id}` | Message edit fanout |
| `message_deleted` | `conversation:{conversation_id}` | Message deletion fanout |
| `receipt_updated` | `conversation:{conversation_id}` | Read/delivery receipt fanout |
| `presence_updated` | `conversation:{conversation_id}` or `user:{user_id}` | Online, offline, or typing state |
| `call_ringing` | `user:{user_id}` or `call:{call_id}` | Incoming call notification |
| `call_ended` | `call:{call_id}` | Call lifecycle completion |

Server events will be produced from trusted service-side flows later. Clients must not directly broadcast message lifecycle or notification events.

## Error Shape

```json
{
  "error": {
    "code": "realtime.unauthorized",
    "message": "Realtime request is unauthorized",
    "correlation_id": "corr_123"
  }
}
```

## Error Codes

| Code | Meaning |
|---|---|
| `realtime.unauthorized` | Missing or invalid socket authentication |
| `realtime.forbidden` | User cannot join the requested topic |
| `realtime.invalid_event` | Event payload is missing required fields |
| `realtime.internal_error` | Unexpected realtime gateway failure |
