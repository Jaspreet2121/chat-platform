# User Service API Contract

## Purpose

Defines the initial public user profile API exposed through the API Gateway. This is a skeleton contract only; authentication, authorization, database writes, and search are not implemented yet.

## Common Rules

- Base path: `/api/v1/users`
- Content type: `application/json`
- Current-user endpoints require bearer auth later; for now they return placeholder current-user data.
- Profile data must not expose private settings.

## Error Shape

```json
{
  "error": {
    "code": "user.invalid_request",
    "message": "Request body is invalid",
    "correlation_id": "corr_123"
  }
}
```

## Error Codes

| Code | HTTP | Meaning |
|---|---:|---|
| user.invalid_request | 400 | Missing or invalid fields |
| user.unauthorized | 401 | Missing or invalid access token |
| user.forbidden | 403 | User cannot access requested profile |
| user.not_found | 404 | User profile does not exist |
| user.internal_error | 500 | Unexpected service failure |

## GET /api/v1/users/me

Returns the current authenticated user's profile, settings, and privacy summary.

Response `200`:

```json
{
  "user_id": "user_placeholder",
  "display_name": "Placeholder User",
  "avatar_media_id": null,
  "bio": "User profile placeholder",
  "settings": {
    "locale": "en",
    "timezone": "UTC"
  },
  "privacy": {
    "last_seen_visibility": "contacts",
    "profile_photo_visibility": "contacts",
    "read_receipts_enabled": true
  }
}
```

## PATCH /api/v1/users/me

Updates the current authenticated user's profile fields. The skeleton accepts only profile fields and returns a placeholder response.

Request:

```json
{
  "display_name": "Jaspreet",
  "bio": "Building chat-platform",
  "avatar_media_id": "media_placeholder"
}
```

Response `200`:

```json
{
  "user_id": "user_placeholder",
  "display_name": "Jaspreet",
  "avatar_media_id": "media_placeholder",
  "bio": "Building chat-platform",
  "updated_at": "2026-06-16T18:30:00Z"
}
```

## GET /api/v1/users/:user_id/profile

Returns a public profile by user ID.

Response `200`:

```json
{
  "user_id": "user_123",
  "display_name": "Placeholder User",
  "avatar_media_id": null,
  "bio": "Public profile placeholder"
}
```

## Nearby People

All Nearby endpoints require a bearer session. The authenticated user/app always come from that
session; client-supplied identity fields are ignored.

**Retention changed in 114.** Presence used to last five minutes and existed only while the Nearby
UI was open. A fix now lasts **up to 8 hours** after the last publish, so people stay discoverable
after closing the screen. Coordinates are still server-only — no response has ever contained a
latitude, longitude, accuracy or exact distance, and none does now.

Two switches govern it, and both are enforced server-side:

| Setting | Default | Meaning |
|---|---|---|
| `enabled` | `true` | The master switch. `false` deletes any live presence row immediately and refuses discovery. |
| `auto_publish` | **`false`** | **The opt-in for background publishing.** Required by `POST /nearby/presence`. Off means presence is only written while the user is actively discovering — the pre-114 behaviour. |

An account with no settings row behaves as `enabled: true, auto_publish: false`, so 114 changed
nobody's exposure by itself.

### POST /api/v1/nearby/discover

Request:

```json
{
  "latitude": 28.6139,
  "longitude": 77.209,
  "accuracy_m": 12,
  "radius_m": 200
}
```

`radius_m` must be `100` or `200`; `accuracy_m` must be at most `100`. Response rows never contain
coordinates or exact distance:

```json
{
  "people": [
    {
      "user_id": "22222222-2222-2222-2222-222222222222",
      "display_name": "Nearby Person",
      "avatar_url": null,
      "distance_bucket_m": 100,
      "last_seen_bucket": "now",
      "relationship": "none"
    }
  ],
  "expires_in_seconds": 28800,
  "radius_m": 200
}
```

`relationship` is `none`, `sent`, `received`, or `connected`.

`last_seen_bucket` is coarse staleness, one of `now` (≤10 min), `1h`, `2h`, `4h`, `8h` — **ceiling
buckets, computed server-side**. The raw `updated_at` is never returned: a timestamp would let a
viewer difference two observations and infer that someone moved, which is exactly what the coarse
distance bucket exists to prevent. `now` deliberately absorbs everything under ten minutes so an
actively-publishing phone does not leak its cadence.

Rows are ordered BLE-confirmed first, then freshest, then nearest.

### POST /api/v1/nearby/presence

Publishes a fix **without running discovery** — the background path (114). Returns no people: a
background worker has no business receiving a list of who is nearby.

Request:

```json
{
  "latitude": 28.6139,
  "longitude": 77.209,
  "accuracy_m": 12
}
```

Response `200`: `{"published": true, "expires_in_seconds": 28800}`.

Requires **both** `enabled` and `auto_publish`. Refusals are distinguishable on purpose:

| Condition | Response |
|---|---|
| `enabled: false` | `403 nearby.disabled` — "Nearby is turned off in your settings" |
| `auto_publish: false` | `403 nearby.publish_disabled` — the user never opted into background sharing; not a fault |
| `accuracy_m > 100` | `400 nearby.accuracy_too_low` |

Rate limited to 30/hour per user — a fix every two minutes, well above any sane cadence and low
enough to cap a runaway worker.

### DELETE /api/v1/nearby/presence

Immediately removes the caller from discovery. Idempotent response: `{"discoverable": false}`.
Unchanged by 114: this and turning `enabled` off both delete the row at once rather than waiting
for the 8-hour expiry.

### GET /api/v1/nearby/requests

Returns profile-enriched `incoming`, `outgoing`, and accepted `connections`. Blocked relationships
are omitted.

### POST /api/v1/nearby/requests

Request: `{"user_id": "..."}`. Both users must still have a live Nearby presence. Returns `201`
with a pending request. Duplicate/reverse pending requests return `409 nearby.request_exists`.

### POST /api/v1/nearby/requests/:request_id/respond

Request: `{"decision": "accept"}` or `{"decision": "decline"}`. Only the recipient may respond.
Accepting creates the durable connection; a block prevents acceptance.
