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
