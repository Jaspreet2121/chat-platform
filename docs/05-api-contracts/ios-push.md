# iOS push registration and payloads (129)

Written for the iOS client team. Everything here is live in the backend; nothing sends until an
Apple provider key is configured on the server.

## Registering device tokens

Same endpoint the Android client uses, with three new fields:

```
POST /api/v1/push/fcm-tokens
{ "token": "<APNs device token>", "platform": "ios", "kind": "alert", "environment": "production" }
```

**Register twice.** An iPhone has two push credentials and they are not interchangeable:

| `kind` | Topic | Carries |
|---|---|---|
| `alert` | `com.growblic.exway` | message notifications |
| `voip` | `com.growblic.exway.voip` | incoming calls, and only calls |

They are stored as separate rows, so registering one never overwrites the other. Sending a call to
an alert token is rejected by Apple as `DeviceTokenNotForTopic`; sending a message to a VoIP token
is worse, because iOS terminates an app that takes a VoIP push without reporting a call to CallKit.

**`environment` is a property of how the build was signed, not of the server.**

| Build | `environment` |
|---|---|
| Debug, run from Xcode | `sandbox` |
| TestFlight | `production` |
| App Store | `production` |

TestFlight is a production build and uses the production APNs host. Sending a TestFlight token as
`sandbox` puts it at the wrong host and every push to it fails with `BadDeviceToken`, which names
nothing useful.

Omitting `kind` defaults to `alert`; omitting `environment` defaults to `production`. Unknown values
fall back the same way rather than being refused — a handset with a malformed registration still
gets push rather than silence.

The device id comes from the session, never from the body. A `device_id` in the body is ignored.

`DELETE /api/v1/push/fcm-tokens` with `{"token": "..."}` removes one. The server also prunes a token
itself when Apple answers `BadDeviceToken`, `Unregistered` or `DeviceTokenNotForTopic`.

## Message pushes (alert)

```json
{
  "aps": {
    "alert": { "title": "Ada", "body": "hello there" },
    "badge": 7,
    "sound": "default",
    "mutable-content": 1,
    "thread-id": "<conversation_id>"
  },
  "type": "message",
  "conversation_id": "…", "message_id": "…",
  "sender_id": "…", "sender_name": "Ada",
  "unread_count": 3,
  "group_name": "Team"
}
```

`group_name` is present only for groups. `badge` is the account's total unread across conversations;
`unread_count` is this conversation's.

`mutable-content` is always 1, so the Notification Service Extension always gets to run.

**Sealed conversations add `"sealed": true` and carry no plaintext.** The body is the generic string
`"New message"` — the server holds ciphertext and has nothing else to send. The extension should
fetch and decrypt locally; the flag is what tells it there is something to fetch rather than leaving
it to infer that from an absence. An ordinary message carries no `sealed` key at all, so the
extension must not wait on a fetch for one.

## Call pushes (VoIP)

```json
{ "aps": {}, "type": "call", "call_id": "…", "call_type": "voice",
  "caller_id": "…", "caller_name": "Ada", "e2ee": true, "conversation_id": "…" }
```

No `aps.alert`, deliberately: CallKit draws the incoming-call UI and a banner beside it is wrong.
Report the call to CallKit immediately on receipt — iOS terminates the app otherwise.

`e2ee` is a display hint so the ring UI can show the lock straight away. The sealed key envelopes
never ride a push; fetch `GET /api/v1/calls/:call_id` for them.

The stop-ringing push arrives on the same VoIP token:

```json
{ "aps": {}, "type": "call_cancelled", "call_id": "…", "reason": "timeout" }
```

A handset ringing off a VoIP push has no socket, so this is the only way the ring stops before iOS
gives up on the call.

## Account deletion

App Store guideline 5.1.1(v):

```
POST /api/v1/users/me/delete
{ "phone_number": "+15550199001" }
```

204 on success. The phone number is the re-auth guard and must match the account's registered
number; formatting is normalised, so spaces and a leading `00` are fine. `403
account.reauth_failed` on a mismatch, `403 account.undeletable` for an admin account, `404
account.not_found` otherwise.

Every session is dead by the time the response is written. Messages already delivered to other
people stay in their chats and render as being from a deleted account.
