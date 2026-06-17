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
