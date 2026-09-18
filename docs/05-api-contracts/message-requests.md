# Message requests (schema 128)

A first direct message from a **stranger** does not land in the recipient's inbox. It waits in a
separate bucket until they accept it. The sender sees no difference for their first three messages.

Written for client engineers on web and Android.

## Who is a stranger

The server decides, at conversation-creation time only. Two users are strangers when **all** of these
are absent:

- a prior shared **active** conversation, direct or group;
- a nearby connection between them;
- a dating match between them.

**Contacts are not a server signal.** Contact sync is stateless and stores nothing, so the server
cannot know whether the sender is in the recipient's address book, and it will not start storing a
social graph to find out. A client that has the address book may badge a request as "in your
contacts" itself. That badge changes nothing about which bucket the chat is in.

## Reading the buckets

`GET /api/v1/conversations` takes one scope, and every conversation is in exactly one list.

| Request | Returns |
|---|---|
| `GET /api/v1/conversations` | the normal inbox. Excludes archived chats **and** unaccepted requests. |
| `GET /api/v1/conversations?archived=true` | archived chats. Still excludes unaccepted requests. |
| `GET /api/v1/conversations?scope=requests` | unaccepted requests only. |

Every row carries `request_pending`, a boolean, in **every** scope. It is always present. A pending
row and an accepted row have the identical key set, so one renderer handles both and accepting
changes a value rather than a shape. The same is true of the `conversation_updated` socket frame,
which carries pending rows too so an open client updates live.

## Answering a request

Both are `POST`, both are for the recipient, and both are silent to the sender.

```
POST /api/v1/conversations/{conversation_id}/request/accept
POST /api/v1/conversations/{conversation_id}/request/decline
```

**Accept** clears the pending flag. The chat moves into the normal inbox, notifications resume, and
the pair now counts as a shared conversation for last-seen, status visibility and profile photos.
Messages that arrived while the request was pending are **not** retro-counted as unread; they are
history, and the list shows them as such.

**Decline** blocks the sender and archives the chat, in one transaction. The sender is told nothing:
no frame, no push, no error. Their later messages take the existing block path, where they still see
a single tick. The chat is reachable in `?archived=true`; nothing is deleted.

Both answer `404 conversations.request_not_found` when there is no pending request for that
conversation, when it has already been answered, or when the caller is not the recipient. The three
are deliberately indistinguishable, so nobody can probe whether a request is sitting unanswered in
someone else's bucket.

Both broadcast `conversation_updated` to the caller's **own** devices only, exactly as archive and
pin do.

## What the sender sees

Nothing changes for the first three messages. The realtime frame still reaches the recipient's
device, so the delivered receipt behaves exactly as it does today. There is no "request sent"
signal, no read of the recipient's decision, and no way to tell a pending request from an ordinary
chat.

The fourth message to a request that has not been accepted is refused:

| Path | Status | Code |
|---|---|---|
| `POST /api/v1/conversations/{id}/messages` | 429 | `message.request_limit` |
| socket `message:create` | error reply | `message.request_limit` |
| `POST /v1/conversations/{id}/messages` | 429 | `v1.message_request_limit` |

All three carry a `retry-after`. The budget is three messages per pair per seven days and it stops
applying the moment the recipient accepts. A recipient who replies before accepting spends nothing:
the budget belongs to the stranger.

The budget FAILS OPEN. If the server cannot reach its counter, the message is sent rather than
refused, and the server logs that it could not count. A client will therefore never see this refusal
because of a server-side outage — only because three messages really have been sent. Between
2026-09-18 and the fix this was not true: the counter was unreachable in production and the refusal
fired on the first message of every pair. If you are testing against a deployment older than that,
that is what you are seeing.

Treat this as a wait, not a wall. Show the sender that the other person has not replied yet rather
than an error.

## Rate limits that changed with this feature

| Endpoint | Limit | On limiter outage |
|---|---|---|
| `POST /api/v1/conversations` | 20/hour per user | allow |
| `POST /api/v1/auth/otp/request` | 3/60s per (address, phone) **and** 30/hour per address | reject |

The conversation-creation limit answers with `429 conversations.rate_limited` and a `retry-after`.
