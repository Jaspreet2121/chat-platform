# Calls — REST and realtime contract

Written from the code on 2026-09-23 (`api_gateway_web/router.ex`, `controllers/call_controller.ex`,
`realtime_gateway/call_signaling.ex`, `conversation_service/call_store.ex`, the notification senders).
Where this file and the code disagree, the code wins and this file is wrong — fix it here.

Three kinds of call share one `calls` row shape and one `/api/v1/calls` surface:

| kind | how it starts | who is "in" it |
|---|---|---|
| `direct` | `call:invite` over the socket, or `POST /v1/calls` (integrators) | `caller_id` and `callee_id` |
| `group` | `call:group_invite` on a group conversation | one `group_call_participants` row per member |
| `adhoc` | `call:adhoc_invite` with a list of user ids — **no conversation** | participant rows only |
| `link` | `POST /api/v1/call-links/:id/join` | participant rows (joiners), `pending_approval` until the host admits |

`group`, `adhoc` and `link` are "group-like": every rule below that says *group* applies to all three
unless it says otherwise.

## REST — `/api/v1/calls` (session bearer)

| Method | Path | Who | What |
|---|---|---|---|
| `GET` | `/calls` | anyone | Call history for the session user, newest first, keyset `cursor`. |
| `GET` | `/calls/:id` | a **party** | One call's live state — the push-woken member's route to the sealed `e2ee_offer`. |
| `POST` | `/calls/token` | a **party** | `{ "room": "call-<id>" }` → a LiveKit access token for that room. |
| `POST` | `/calls/:id/reject` | direct: the **callee**; group: any **participant** | Decline. See below. |
| `POST` | `/calls/:id/join` | group-like: any **participant** | Answer a group ring with no socket. See below. |

**"A party"** means: for `direct`, the caller or callee; for group-like, a user with a
`group_call_participants` row for this call whose status is not `pending_approval` — the same
predicate for `show`, `token` and `join` (`authorized_for_call?/3`). Anyone else gets **404
`calls.not_found`**, never 403: a call id must not confirm its own existence to a stranger.

### `GET /calls/:id` — live state

```json
{ "id", "room_name", "kind", "caller_id", "callee_id", "conversation_id", "type",
  "status", "created_at", "answered_at", "ended_at",
  "e2ee": bool, "e2ee_accepted": bool|null, "e2ee_offer": {...}|null }
```

`e2ee_offer` is the sealed key envelope set (E2EE_FRAME.md §10); it is **null once the call is
terminal** — the key died with the call. Group calls have no E2EE today (`e2ee: false`).

### `POST /calls/:id/reject` — decline

- **direct**: only the callee. `ringing` → `declined` under an atomic `expected_status` guard;
  `call:rejected` to the caller; the same missed-call pill the socket decline writes. Anyone else:
  403 `calls.forbidden`. A call that already left `ringing` (the 35 s timeout won, a double tap):
  **idempotent 200**, nothing written or broadcast.
- **group-like**: any participant. Writes **their own row** `declined` (+ `declined_at`);
  `call:participant_declined { call_id, user_id }` to the other invited/joined members; a
  `call.cancelled reason:"declined"` push to the decliner's own other devices. Already declined, or
  the call already closed: **idempotent 200**, nothing written or broadcast. Not a participant: 404.

Response in every 200: `{ "call_id" }`.

### `POST /calls/:id/join` — answer a group ring without a socket

For the member woken by a VoIP/FCM push whose app has no channel yet. Runs the **same store
transition** as `call:group_join` (`join_group_call`: the row becomes `joined`, and the first join
flips the call `ringing → ongoing`), broadcasts the same `call:participant_joined { call_id,
user_id, joined_at }` to the invited/joined members, and sends `call.cancelled reason:"answered"` to
the member's own other devices. Then fetch a token via `POST /calls/token`, exactly as after a socket
join.

```json
{ "call_id", "room": "call-<id>", "participants": [ { "user_id", "status", "joined_at", ... } ] }
```

Errors: 400 `calls.not_group_call` (a direct call — answer over the socket); 409 `calls.ended`;
404 `calls.not_found` (unknown, or not a participant); 503 `calls.unavailable`.

## Per-participant state (group-like)

`group_call_participants (call_id, user_id)`, one row per member:

| status | meaning |
|---|---|
| `invited` | rung, not yet answered. `rung_at` = when this ring was emitted (131) |
| `joined` | answered. `joined_at` set |
| `declined` | refused. `declined_at` set (131) |
| `left` | was in the call and left. `left_at` set |
| `missed` | still `invited` when the ring window closed |
| `pending_approval` | link calls only: waiting for the host. Not a party until admitted |

"Ringing" is not a row state: it is call `status = "ringing"` ∧ row `invited` ∧ now <
`rung_at + 35 s`. A re-invite of a declined/left/missed member (`call:group_add`) resets the row to
`invited` with a **new** `rung_at`, so the ring deadline starts again for that ring.

The call closes when the last `joined` member leaves, or when the ring window ends with nobody but
the initiator ever joined (`missed`, plus one "Missed group call" pill) or with some earlier joiner
(`ended`).

## Realtime — socket events (`user:<id>` topics)

Direct: `call:incoming`, `call:accepted`, `call:rejected`, `call:cancelled`, `call:ended`,
`call:missed`. Client → server: `call:invite`, `call:accept`, `call:reject`, `call:cancel`,
`call:hangup`.

Group-like, server → client:

| event | to | payload |
|---|---|---|
| `call:group_incoming` | each rung member | `{ call_id, room, conversation_id (null for adhoc), type, caller_id, caller_name, participants[], caller_avatar_url? }` — the initial ring, a mid-call add, and the promote target all use this one shape |
| `call:participant_joined` | invited + joined | `{ call_id, user_id, joined_at }` |
| `call:participant_declined` | invited + joined | `{ call_id, user_id }` |
| `call:participant_left` | invited + joined | `{ call_id, user_id }` |
| `call:promoted` | the other peer of a promoted 1:1 | `{ call_id, room, conversation_id, type, new_user_id, actor_id }` |
| `call:group_ended` | every participant, any status | `{ call_id }` — tear down from any state |

Client → server: `call:group_invite { conversation_id, type }`, `call:adhoc_invite { user_ids, type }`
(rate-limited: 5 per 60 s, 30 per day, ≤ 8 targets), `call:group_join { call_id }`,
`call:group_decline { call_id }`, `call:group_leave { call_id }`, `call:group_add { call_id, user_id |
phone }`, `call:promote`.

## Push — `call.events.v1`

Produced by the gateway (realtime), consumed by notification-service, which fans each event to web
push, FCM (Android rows only) and APNs VoIP (iOS `voip` tokens). **Every event is keyed by the
recipient**, so a member's ring and the stop that chases it stay in order on one partition.

| type | when | key |
|---|---|---|
| `call.incoming` | direct ring (`CALL_PUSH_ENABLED`) | callee |
| `call.group_incoming` | group/adhoc ring, and a mid-call add — **one event per rung member** (`CALL_GROUP_PUSH_ENABLED`, default OFF) | that member |
| `call.cancelled` | direct: caller cancelled / ring timed out. Group: `reason` `answered` (this member joined — stop their other devices), `declined`, `ended`, `missed` (per still-invited member when the call closes) | that member |

Payload common to both rings: `call_id, callee_id, caller_id, caller_name, call_type,
conversation_id, e2ee (display hint only — envelopes never ride a push), correlation_id`. Group rings
add `kind` (`group` | `adhoc` — the client's UI switch), `sent_at` and `ring_deadline_at` (ISO 8601;
`sent_at + 35 s`).

**The stale-ring cutoff.** From `ring_deadline_at`: APNs sets `apns-expiration` to its UNIX time, so
Apple drops a push it has not delivered by then — the only cutoff that helps an app that is not
running; FCM sets `ttl` to the remaining seconds (never below 1 s; 35 s for a direct ring). A device
that receives a ring after the deadline anyway must not ring it — **iOS must still report every
delivered VoIP push to CallKit**, then end it as unanswered.

What each device gets, on the wire: FCM data `{ type:"call", call_id, call_type, caller_id,
caller_name, e2ee:"true|false", conversation_id?, kind?, sent_at?, ring_deadline_at? }` with
`collapse_key: call_<id>`; APNs VoIP `{ aps:{}, type:"call", ...same keys... }` on topic
`com.growblic.exway.voip`, priority 10. Stops: `{ type:"call_cancelled", call_id, reason }`.

## Timers, and what backs them up

- Direct ring timeout: 35 s, in the **caller's** channel process.
- Group/adhoc ring timeout: 35 s, in the **initiator's** channel; a mid-call add arms another in the
  **adder's** channel. On fire: still-`invited` rows → `missed`; then, if nobody is `joined`, the call
  closes.
- **Reaper** (`ApiGatewayWeb.CallReaper`): rides every `/api/v1/calls/*` request, one run per node per
  60 s. For each group/adhoc call still `ringing` more than **60 s** (35 + 25 slack) after creation —
  i.e. a timer that died with its channel — it runs the exact timeout handler. Direct calls are never
  touched by it. It does **not** close `ongoing` calls: from the database an abandoned call and a
  long real one are the same, and ending one would send `call:group_ended` to people mid-call. That
  waits on LiveKit room/participant webhooks (roadmap).

## Not in v1 (recorded)

Group E2EE (sender keys, parked); key rotation mid-call; re-offer on device-set change while ringing;
an `ongoing`-call reaper (above); web sending/rendering the group push (web rings over the socket).
