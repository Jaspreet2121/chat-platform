# Conversation Service API Contract

## Purpose

Defines the initial public conversation API exposed through the API Gateway. This is a skeleton contract only; authentication, authorization, database writes, and Kafka publishing are not implemented yet.

## Common Rules

- Base path: `/api/v1/conversations`
- Content type: `application/json`
- Conversation access checks require real auth later.
- PostgreSQL will be the source of truth for conversation metadata and participants.
- Future events include `conversation.created.v1`, `conversation.participant_added.v1`, `conversation.participant_removed.v1`, and `conversation.updated.v1`.

## Error Shape

```json
{
  "error": {
    "code": "conversation.invalid_request",
    "message": "Request body is invalid",
    "correlation_id": "corr_123"
  }
}
```

## Error Codes

| Code | HTTP | Meaning |
|---|---:|---|
| conversation.invalid_request | 400 | Missing or invalid fields |
| conversation.unauthorized | 401 | Missing or invalid access token |
| conversation.forbidden | 403 | User cannot access or modify conversation |
| conversation.not_found | 404 | Conversation does not exist |
| conversation.internal_error | 500 | Unexpected service failure |

## POST /api/v1/conversations

Creates a direct, group, or business conversation.

Request:

```json
{
  "type": "group",
  "participant_user_ids": ["user_123", "user_456"],
  "title": "Launch Team",
  "tenant_id": null
}
```

Response `201`:

```json
{
  "conversation_id": "conv_123",
  "tenant_id": null,
  "type": "group",
  "title": "Launch Team",
  "created_by": "user_placeholder",
  "participant_user_ids": ["user_123", "user_456"],
  "created_at": "2026-06-17T10:00:00Z"
}
```

## GET /api/v1/conversations

Lists conversations visible to the current user.

Response `200`:

```json
{
  "conversations": [
    {
      "conversation_id": "conv_placeholder",
      "type": "group",
      "title": "Launch Team",
      "last_message_preview": null,
      "unread_count": 0,
      "updated_at": "2026-06-17T10:00:00Z"
    }
  ]
}
```

## Best Friends (125) — DM streaks and the mutual pin

### Streaks are SERVER-computed; stop computing them on the device

A streak is the number of consecutive local-calendar days on which **both sides** of a direct chat
sent at least one message. A gap resets it to 1 at the next such day.

Android computed this locally and every device counted from its own history, so the same DM read 4
on one handset and 6 on another. **The server is now the source of truth.** Read `streak_days` off
the conversation row and display it; do not recompute, and do not reconcile it against local
history.

`GET /api/v1/conversations` rows carry:

| field | type | meaning |
|---|---|---|
| `streak_days` | int | Consecutive both-sides days. **Always present.** `0` on a group, and `0` on a direct chat with no counted day yet. |
| `best_friend` | bool | Whether **you** have pinned this chat. Never says whether the other side has. |

### The day boundary is the SENDER's

A message counts toward the day it was sent in, **where it was sent**. Send
`tz_offset_minutes` on message create — minutes EAST of UTC, the sign
`-Date.getTimezoneOffset()` produces in JavaScript and `ZoneOffset.getTotalSeconds() / 60` in Java.
When the field is absent the server uses **UTC**.

```json
POST /api/v1/conversations/:id/messages
{ "message_type": "text", "body": "hey", "tz_offset_minutes": 330 }
```

This matters at the edges of the day: 23:30 UTC is already tomorrow at +05:30, and a message sent
then should extend *that* day's streak, not the previous one. Offsets outside ±14 hours are ignored
(UTC is used) so a client cannot choose which day its message lands in. Values may be sent as a
number or a numeric string.

The choice is deliberately one-sided: attributing a send to the recipient's zone, or to the
server's, would make the same message count for different days depending on who asked.

### PUT /api/v1/users/me/best-friend

Pin one direct chat as your best friend, or clear it. **At most one per user** — pinning a second
replaces the first, with no separate unpin call needed.

The action is mounted inside the `/api/v1/users` scope, so the path carries `users`. This document
said `/api/v1/me/best-friend` until 2026-09-18; that path 404s and cost an Android debugging session
on a real device.

```json
PUT /api/v1/users/me/best-friend
{ "conversation_id": "550e8400-e29b-41d4-a716-446655440000" }   // pin
{ "conversation_id": null }                                      // clear
```

Response `200`:

```json
{ "conversation_id": "550e8400-…", "best_friend": true, "mutual": false }
```

Errors: `403 conversations.forbidden` (not a member), `422 conversations.best_friend_direct_only`
(a group — there is no pair to be mutual with), `404 conversations.not_found`.

### `best_friend_mutual` (user topic)

**A pin is private until it is returned.** One side pinning tells the other nothing; the inbox row
carries only your own `best_friend` flag. The moment **both** members have pinned each other, both
are told at once — because that is now a fact about the pair, not about one person.

Emitted on `user:<id>` for **both members and nobody else**, after the write:

```json
{ "conversation_id": "550e8400-…", "mutual": true }
```

`mutual: false` is emitted to the same two people when a mutual pin is cleared, so a client that lit
up does not stay lit. Do not infer mutuality from anything else — the conversation list will never
tell you what the other person chose.

## GET /api/v1/conversations/:conversation_id
## GET /api/v1/conversations/:conversation_id

Returns conversation details.

Response `200`:

```json
{
  "conversation_id": "conv_placeholder",
  "tenant_id": null,
  "type": "group",
  "title": "Launch Team",
  "participants": [
    {
      "user_id": "user_123",
      "role": "member",
      "joined_at": "2026-06-17T10:00:00Z"
    }
  ]
}
```

## POST /api/v1/conversations/:conversation_id/participants

Adds a participant to a conversation.

Request:

```json
{
  "user_id": "user_789",
  "role": "member"
}
```

Response `200`:

```json
{
  "conversation_id": "conv_123",
  "user_id": "user_789",
  "role": "member",
  "joined_at": "2026-06-17T10:00:00Z"
}
```

## DELETE /api/v1/conversations/:conversation_id/participants/:user_id

Removes a participant from a conversation.

Response `200`:

```json
{
  "conversation_id": "conv_123",
  "user_id": "user_789",
  "removed": true
}
```

## Pinned messages (092)

Up to 3 per conversation, visible to every participant. **Not** the same as pinning a *conversation*
(`conversation_participants.pinned_at`, 076), which is a per-user inbox preference.

```
PUT    /api/v1/conversations/:conversation_id/messages/:message_id/pin
DELETE /api/v1/conversations/:conversation_id/messages/:message_id/pin
  -> 200 { "conversation_id": "...", "message_id": "...", "pinned": true|false }

GET    /api/v1/conversations/:conversation_id/pins
  -> 200 { "pinned_messages": [
             { "message_id": "...", "pinned_by": "...", "pinned_at": "2026-08-03T10:00:00Z" }
           ] }
```

Ids only, newest pin first — the client already holds the bodies from the transcript, and a body can
be edited or deleted underneath a cached copy.

**Who can pin:** groups — owner and admin (the tier that owns group profile and settings, because
pinning mutates a shared view). Direct chats — either participant. It is deliberately *not* the
owner-only tier, which is reserved for membership changes.

**Errors:** `conversation.pin_forbidden` (403, not an admin), `message.pin_limit` (409, cap reached),
`message.not_found` (404 — unknown message, deleted message, a message belonging to another
conversation, or the caller not being a participant; the same code for all four so the endpoint
cannot be used to probe).

**Realtime:** a pin change fans `conversation_updated` to every active participant with trigger
`"pin"`. It does not reuse the `pref` trigger, which is scoped to the acting user only.

### THE PINNED LIST IS MASKED PER USER

**Two people in the same group can legitimately see different pinned bars.** A pin is
per-conversation, but `cleared_before`, the rolling `auto_delete_seconds` window and per-user
delete-for-me markers are per-user, and a pin overrides none of them. A client must not assume the
pinned set is identical across participants, and must not cache one user's pinned list as the
conversation's.
