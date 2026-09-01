# Media Service API Contract

## Purpose

Defines the initial media upload and secure access API exposed through the API Gateway. The storage boundary can generate MinIO/S3 presigned URLs when enabled; live upload completion verification and object metadata persistence remain future work.

## Common Rules

- Base path: `/api/v1/media`
- Content type: `application/json`
- DB-backed/auth-backed mode derives the owner/requester from the authenticated session.
- Clients must not send or control `owner_user_id`.
- Supported content types for this slice:
  - `image/jpeg`
  - `image/png`
  - `image/webp`
  - `application/pdf`
  - `audio/mpeg`
  - `audio/mp4`
  - `video/mp4`

## Error Shape

```json
{
  "error": {
    "code": "media.invalid_request",
    "message": "Request body is invalid",
    "correlation_id": "corr_123"
  }
}
```

## Error Codes

| Code | HTTP | Meaning |
|---|---:|---|
| media.invalid_request | 400 | Missing or invalid fields |
| media.unauthorized | 401 | Missing or invalid access token |
| media.forbidden | 403 | User cannot access media |
| media.not_found | 404 | Media does not exist |
| media.purpose_required | 422 | `purpose` was absent or empty |
| media.purpose_invalid | 422 | `purpose` is not one of the accepted values |
| media.conversation_required | 422 | `conversation_id` is required for this `purpose` |
| media.internal_error | 500 | Unexpected service failure |

## POST /api/v1/media/uploads

Creates an upload request and returns an upload URL boundary response.

Request:

```json
{
  "purpose": "message",
  "conversation_id": "c_123",
  "filename": "photo.png",
  "content_type": "image/png",
  "size_bytes": 12345
}
```

### `purpose` — required

There is no default. A request that omits `purpose`, or sends an empty string, is rejected
`422 media.purpose_required`; a value outside the list below is rejected `422 media.purpose_invalid`.
(An earlier revision of this document showed a request with no `purpose` at all — that shape was
silently coerced to `"message"` and no longer works.)

| `purpose` | What it is | `conversation_id` |
|---|---|---|
| `message` | A chat attachment | Optional today. Send it — it is what authorizes the uploader against that conversation, and it is expected to become required. |
| `sealed_media` | An end-to-end encrypted attachment | **Required.** Omitting it is `422 media.conversation_required`. |
| `group_avatar` | A group's photo | Optional; when present the caller must be that group's owner/admin. |
| `user_avatar` | A user's own photo | Not applicable. |
| `status` | A 24-hour status post | Not applicable. |

`conversation_id` is validated when supplied: the uploader must be an active participant, and a
conversation belonging to another tenant is reported as `404 media.not_found` rather than `403`, so
the response never confirms that an id exists elsewhere.

The same rules apply to the multipart initiation route (`POST /api/v1/media/upload/multipart`) —
both run the same validation.

### The integrator route differs

`POST /v1/media/uploads` (the `/v1` surface used by `@growblic/client-core`) accepts only
`message`, `user_avatar` and `group_avatar`, and **requires `conversation_id` for `message` and
`group_avatar`**. It reports every one of these failures as `400 invalid_request`, not `422` — the
`/v1` error convention, deliberately not the first-party one.

Response `201`:

```json
{
  "media_id": "media_placeholder",
  "object_key": "media/user_123/media_placeholder/photo.png",
  "upload_url": "http://localhost:9000/chat-media/media/user_123/media_placeholder/photo.png?X-Amz-Algorithm=AWS4-HMAC-SHA256&...",
  "expires_at": "2026-06-17T10:15:00Z"
}
```

## POST /api/v1/media/uploads/:media_id/complete

Marks an upload complete. Live object verification is future work.

Request:

```json
{
  "object_key": "media/user_123/media_placeholder/photo.png"
}
```

Response `200`:

```json
{
  "media_id": "media_placeholder",
  "status": "ready"
}
```

## GET /api/v1/media/:media_id/download

Returns a short-lived download URL boundary response.

Query:

```txt
object_key=media/user_123/media_placeholder/photo.png
```

Response `200`:

```json
{
  "media_id": "media_placeholder",
  "download_url": "http://localhost:9000/chat-media/media/user_123/media_placeholder/photo.png?X-Amz-Algorithm=AWS4-HMAC-SHA256&...",
  "expires_at": "2026-06-17T10:15:00Z"
}
```

## Message Integration Note

Message sending can attach `media_id` from this API to Message Service requests
with `message_type: "media"` and optional `caption`. The current message slice
does not verify live MinIO object existence; that remains future work alongside
live object metadata checks.
