# Kafka Event Catalog

## Purpose

This document defines all Kafka topics and events used by the chat-platform backend.

Kafka is used for durable asynchronous communication between microservices.

## Why Kafka

Kafka will be used for:

- Message fanout
- Push notification workflows
- Audit logging
- Search indexing
- Analytics events
- Realtime delivery events
- Call lifecycle events
- Media processing events

## Core Rules

- Every event must be versioned.
- Every event name must end with version number like `.v1`.
- Events should be immutable.
- Events should contain enough data for consumers to process them.
- Events should not contain sensitive secrets.
- Breaking event changes require a new version.
- Consumers must be idempotent.
- Producers should include event_id for deduplication.
- Every event must include occurred_at.

## Event Naming Format

Use this format:

domain.entity_action.version

Examples:

- auth.user_registered.v1
- message.created.v1
- conversation.created.v1
- notification.sent.v1

## Standard Event Envelope

Every Kafka event should follow this structure:

| Field | Type | Required | Description |
|---|---|---|---|
| event_id | string | yes | Unique event ID |
| event_type | string | yes | Event name |
| event_version | integer | yes | Event version |
| producer | string | yes | Service that produced the event |
| occurred_at | string | yes | ISO timestamp |
| correlation_id | string | yes | Request trace ID |
| tenant_id | string | no | Tenant/organization ID |
| actor_user_id | string | no | User who caused event |
| payload | object | yes | Event-specific payload |

## Example Event Envelope

```json
{
  "event_id": "evt_123",
  "event_type": "message.created.v1",
  "event_version": 1,
  "producer": "message-service",
  "occurred_at": "2026-06-16T10:00:00Z",
  "correlation_id": "corr_123",
  "tenant_id": null,
  "actor_user_id": "user_123",
  "payload": {}
}
```

---

# Topic Strategy

## Initial Topic Style

For local development and MVP, use domain-level topics:

| Topic | Purpose |
|---|---|
| auth.events.v1 | Auth events |
| user.events.v1 | User/profile events |
| tenant.events.v1 | B2B organization events |
| conversation.events.v1 | Conversation events |
| message.events.v1 | Message lifecycle events |
| realtime.events.v1 | Realtime gateway events |
| notification.events.v1 | Notification events |
| media.events.v1 | Media events |
| call.events.v1 | Call events |
| moderation.events.v1 | Moderation events |
| audit.events.v1 | Audit events |

## Future Topic Style

At large scale, high-volume events can move to dedicated topics:

| Topic | Purpose |
|---|---|
| message.created.v1 | High-volume message created events |
| message.receipts.v1 | Delivery/read receipt events |
| notification.requested.v1 | Notification requests |
| realtime.delivery.v1 | Realtime delivery events |

---

# Auth Events

## auth.user_registered.v1

Topic:

auth.events.v1

Produced by:

auth-service

Consumed by:

- user-service
- audit-service
- analytics-service
- notification-service

Payload:

| Field | Type | Required |
|---|---|---|
| user_id | string | yes |
| phone_number | string | no |
| email | string | no |
| registration_method | string | yes |
| device_id | string | no |

Example:

```json
{
  "user_id": "user_123",
  "phone_number": "+919999999999",
  "email": null,
  "registration_method": "phone_otp",
  "device_id": "device_123"
}
```

## auth.user_logged_in.v1

Topic:

auth.events.v1

Produced by:

auth-service

Consumed by:

- audit-service
- analytics-service

Payload:

| Field | Type | Required |
|---|---|---|
| user_id | string | yes |
| device_id | string | yes |
| platform | string | yes |
| ip_address | string | no |
| user_agent | string | no |

## auth.user_logged_out.v1

Topic:

auth.events.v1

Produced by:

auth-service

Consumed by:

- audit-service
- realtime-gateway

Payload:

| Field | Type | Required |
|---|---|---|
| user_id | string | yes |
| device_id | string | yes |
| session_id | string | yes |

## auth.device_registered.v1

Topic:

auth.events.v1

Produced by:

auth-service

Consumed by:

- notification-service
- audit-service

Payload:

| Field | Type | Required |
|---|---|---|
| user_id | string | yes |
| device_id | string | yes |
| platform | string | yes |
| push_token | string | no |

---

# User Events

## user.profile_created.v1

Topic:

user.events.v1

Produced by:

user-service

Consumed by:

- audit-service
- analytics-service

Payload:

| Field | Type | Required |
|---|---|---|
| user_id | string | yes |
| display_name | string | yes |
| avatar_media_id | string | no |

## user.profile_updated.v1

Topic:

user.events.v1

Produced by:

user-service

Consumed by:

- audit-service
- search-service
- analytics-service

Payload:

| Field | Type | Required |
|---|---|---|
| user_id | string | yes |
| changed_fields | array | yes |

## user.avatar_updated.v1

Topic:

user.events.v1

Produced by:

user-service

Consumed by:

- audit-service
- media-service

Payload:

| Field | Type | Required |
|---|---|---|
| user_id | string | yes |
| avatar_media_id | string | yes |

---

# Tenant Events

## tenant.created.v1

Topic:

tenant.events.v1

Produced by:

tenant-service

Consumed by:

- audit-service
- billing-service
- analytics-service

Payload:

| Field | Type | Required |
|---|---|---|
| tenant_id | string | yes |
| name | string | yes |
| slug | string | yes |
| created_by | string | yes |

## tenant.member_added.v1

Topic:

tenant.events.v1

Produced by:

tenant-service

Consumed by:

- notification-service
- audit-service

Payload:

| Field | Type | Required |
|---|---|---|
| tenant_id | string | yes |
| user_id | string | yes |
| role_id | string | yes |
| added_by | string | yes |

## tenant.member_removed.v1

Topic:

tenant.events.v1

Produced by:

tenant-service

Consumed by:

- audit-service
- realtime-gateway

Payload:

| Field | Type | Required |
|---|---|---|
| tenant_id | string | yes |
| user_id | string | yes |
| removed_by | string | yes |

## tenant.role_assigned.v1

Topic:

tenant.events.v1

Produced by:

tenant-service

Consumed by:

- audit-service

Payload:

| Field | Type | Required |
|---|---|---|
| tenant_id | string | yes |
| user_id | string | yes |
| role_id | string | yes |
| assigned_by | string | yes |

---

# Conversation Events

## conversation.created.v1

Topic:

conversation.events.v1

Produced by:

conversation-service

Consumed by:

- message-service
- realtime-gateway
- notification-service
- audit-service

Payload:

| Field | Type | Required |
|---|---|---|
| conversation_id | string | yes |
| tenant_id | string | no |
| type | string | yes |
| created_by | string | yes |
| participant_user_ids | array | yes |

## conversation.participant_added.v1

Topic:

conversation.events.v1

Produced by:

conversation-service

Consumed by:

- realtime-gateway
- notification-service
- audit-service

Payload:

| Field | Type | Required |
|---|---|---|
| conversation_id | string | yes |
| user_id | string | yes |
| added_by | string | yes |
| role | string | yes |

## conversation.participant_removed.v1

Topic:

conversation.events.v1

Produced by:

conversation-service

Consumed by:

- realtime-gateway
- audit-service

Payload:

| Field | Type | Required |
|---|---|---|
| conversation_id | string | yes |
| user_id | string | yes |
| removed_by | string | yes |

## conversation.updated.v1

Topic:

conversation.events.v1

Produced by:

conversation-service

Consumed by:

- realtime-gateway
- audit-service

Payload:

| Field | Type | Required |
|---|---|---|
| conversation_id | string | yes |
| changed_fields | array | yes |
| updated_by | string | yes |

---

# Message Events

## message.created.v1

Topic:

message.events.v1

Produced by:

message-service

Consumed by:

- realtime-gateway
- notification-service
- search-service
- audit-service
- analytics-service

Payload:

| Field | Type | Required |
|---|---|---|
| conversation_id | string | yes |
| message_id | string | yes |
| sender_user_id | string | yes |
| message_type | string | yes |
| body_preview | string | no |
| media_id | string | no |
| created_at | string | yes |

Example:

```json
{
  "conversation_id": "conv_123",
  "message_id": "msg_123",
  "sender_user_id": "user_123",
  "message_type": "text",
  "body_preview": "Hello",
  "media_id": null,
  "created_at": "2026-06-16T10:00:00Z"
}
```

## message.edited.v1

Topic:

message.events.v1

Produced by:

message-service

Consumed by:

- realtime-gateway
- search-service
- audit-service

Payload:

| Field | Type | Required |
|---|---|---|
| conversation_id | string | yes |
| message_id | string | yes |
| edited_by | string | yes |
| edited_at | string | yes |

## message.deleted.v1

Topic:

message.events.v1

Produced by:

message-service

Consumed by:

- realtime-gateway
- search-service
- audit-service

Payload:

| Field | Type | Required |
|---|---|---|
| conversation_id | string | yes |
| message_id | string | yes |
| deleted_by | string | yes |
| delete_type | string | yes |
| deleted_at | string | yes |

## message.delivered.v1

Topic:

message.events.v1

Produced by:

realtime-gateway

Consumed by:

- message-service
- analytics-service

Payload:

| Field | Type | Required |
|---|---|---|
| conversation_id | string | yes |
| message_id | string | yes |
| delivered_to_user_id | string | yes |
| delivered_at | string | yes |

## message.read.v1

Topic:

message.events.v1

Produced by:

realtime-gateway

Consumed by:

- message-service
- analytics-service

Payload:

| Field | Type | Required |
|---|---|---|
| conversation_id | string | yes |
| message_id | string | yes |
| read_by_user_id | string | yes |
| read_at | string | yes |

## message.reaction_added.v1

Topic:

message.events.v1

Produced by:

message-service

Consumed by:

- realtime-gateway
- analytics-service

Payload:

| Field | Type | Required |
|---|---|---|
| conversation_id | string | yes |
| message_id | string | yes |
| user_id | string | yes |
| reaction | string | yes |
| created_at | string | yes |

---

# Realtime Events

## realtime.user_connected.v1

Topic:

realtime.events.v1

Produced by:

realtime-gateway

Consumed by:

- analytics-service
- audit-service

Payload:

| Field | Type | Required |
|---|---|---|
| user_id | string | yes |
| device_id | string | yes |
| connection_id | string | yes |
| connected_at | string | yes |

## realtime.user_disconnected.v1

Topic:

realtime.events.v1

Produced by:

realtime-gateway

Consumed by:

- analytics-service

Payload:

| Field | Type | Required |
|---|---|---|
| user_id | string | yes |
| device_id | string | yes |
| connection_id | string | yes |
| disconnected_at | string | yes |

## realtime.typing_started.v1

Topic:

realtime.events.v1

Produced by:

realtime-gateway

Consumed by:

- analytics-service

Payload:

| Field | Type | Required |
|---|---|---|
| conversation_id | string | yes |
| user_id | string | yes |
| started_at | string | yes |

## realtime.typing_stopped.v1

Topic:

realtime.events.v1

Produced by:

realtime-gateway

Consumed by:

- analytics-service

Payload:

| Field | Type | Required |
|---|---|---|
| conversation_id | string | yes |
| user_id | string | yes |
| stopped_at | string | yes |

---

# Notification Events

## notification.requested.v1

Topic:

notification.events.v1

Produced by:

- message-service
- call-signaling-service
- tenant-service

Consumed by:

notification-service

Payload:

| Field | Type | Required |
|---|---|---|
| notification_id | string | yes |
| recipient_user_id | string | yes |
| notification_type | string | yes |
| title | string | yes |
| body | string | yes |
| data | object | no |

## notification.sent.v1

Topic:

notification.events.v1

Produced by:

notification-service

Consumed by:

- audit-service
- analytics-service

Payload:

| Field | Type | Required |
|---|---|---|
| notification_id | string | yes |
| recipient_user_id | string | yes |
| channel | string | yes |
| sent_at | string | yes |

## notification.failed.v1

Topic:

notification.events.v1

Produced by:

notification-service

Consumed by:

- audit-service
- analytics-service

Payload:

| Field | Type | Required |
|---|---|---|
| notification_id | string | yes |
| recipient_user_id | string | yes |
| channel | string | yes |
| failure_reason | string | yes |
| failed_at | string | yes |

---

# Media Events

## media.upload_requested.v1

Topic:

media.events.v1

Produced by:

media-service

Consumed by:

- audit-service

Payload:

| Field | Type | Required |
|---|---|---|
| media_id | string | yes |
| owner_user_id | string | yes |
| mime_type | string | yes |
| size_bytes | number | yes |

## media.upload_completed.v1

Topic:

media.events.v1

Produced by:

media-service

Consumed by:

- message-service
- audit-service
- analytics-service

Payload:

| Field | Type | Required |
|---|---|---|
| media_id | string | yes |
| owner_user_id | string | yes |
| storage_key | string | yes |
| completed_at | string | yes |

## media.processing_completed.v1

Topic:

media.events.v1

Produced by:

media-service

Consumed by:

- message-service
- notification-service

Payload:

| Field | Type | Required |
|---|---|---|
| media_id | string | yes |
| thumbnail_media_id | string | no |
| duration_seconds | number | no |
| width | number | no |
| height | number | no |
| processed_at | string | yes |

---

# Call Events

## call.started.v1

Topic:

call.events.v1

Produced by:

call-signaling-service

Consumed by:

- realtime-gateway
- notification-service
- audit-service
- analytics-service

Payload:

| Field | Type | Required |
|---|---|---|
| call_id | string | yes |
| conversation_id | string | yes |
| started_by | string | yes |
| call_type | string | yes |
| started_at | string | yes |

## call.ringing.v1

Topic:

call.events.v1

Produced by:

call-signaling-service

Consumed by:

- realtime-gateway
- notification-service

Payload:

| Field | Type | Required |
|---|---|---|
| call_id | string | yes |
| recipient_user_id | string | yes |
| ringing_at | string | yes |

## call.accepted.v1

Topic:

call.events.v1

Produced by:

call-signaling-service

Consumed by:

- realtime-gateway
- analytics-service

Payload:

| Field | Type | Required |
|---|---|---|
| call_id | string | yes |
| accepted_by | string | yes |
| accepted_at | string | yes |

## call.rejected.v1

Topic:

call.events.v1

Produced by:

call-signaling-service

Consumed by:

- realtime-gateway
- analytics-service

Payload:

| Field | Type | Required |
|---|---|---|
| call_id | string | yes |
| rejected_by | string | yes |
| rejected_at | string | yes |

## call.ended.v1

Topic:

call.events.v1

Produced by:

call-signaling-service

Consumed by:

- realtime-gateway
- analytics-service
- audit-service

Payload:

| Field | Type | Required |
|---|---|---|
| call_id | string | yes |
| ended_by | string | yes |
| ended_at | string | yes |
| duration_seconds | number | no |

## call.missed.v1

Topic:

call.events.v1

Produced by:

call-signaling-service

Consumed by:

- notification-service
- analytics-service

Payload:

| Field | Type | Required |
|---|---|---|
| call_id | string | yes |
| missed_by_user_id | string | yes |
| missed_at | string | yes |

---

# Moderation Events

## moderation.user_blocked.v1

Topic:

moderation.events.v1

Produced by:

moderation-service

Consumed by:

- conversation-service
- realtime-gateway
- audit-service

Payload:

| Field | Type | Required |
|---|---|---|
| blocker_user_id | string | yes |
| blocked_user_id | string | yes |
| blocked_at | string | yes |

## moderation.report_created.v1

Topic:

moderation.events.v1

Produced by:

moderation-service

Consumed by:

- audit-service
- notification-service

Payload:

| Field | Type | Required |
|---|---|---|
| report_id | string | yes |
| reporter_user_id | string | yes |
| reported_user_id | string | no |
| reported_message_id | string | no |
| reason | string | yes |
| created_at | string | yes |

## moderation.action_taken.v1

Topic:

moderation.events.v1

Produced by:

moderation-service

Consumed by:

- audit-service
- notification-service

Payload:

| Field | Type | Required |
|---|---|---|
| action_id | string | yes |
| target_user_id | string | yes |
| action_type | string | yes |
| action_by | string | yes |
| created_at | string | yes |

---

# Audit Events

## audit.event_created.v1

Topic:

audit.events.v1

Produced by:

audit-service

Consumed by:

- analytics-service

Payload:

| Field | Type | Required |
|---|---|---|
| audit_log_id | string | yes |
| actor_user_id | string | no |
| tenant_id | string | no |
| action | string | yes |
| target_type | string | yes |
| target_id | string | no |
| created_at | string | yes |

---

# Consumer Groups

## Initial Consumer Groups

| Consumer Group | Service | Consumes |
|---|---|---|
| realtime-gateway-group | realtime-gateway | message.events.v1, conversation.events.v1, call.events.v1 |
| notification-service-group | notification-service | message.events.v1, call.events.v1, notification.events.v1 |
| audit-service-group | audit-service | auth.events.v1, tenant.events.v1, message.events.v1, call.events.v1, moderation.events.v1 |
| analytics-service-group | analytics-service | all domain events |
| search-service-group | search-service | message.events.v1, user.events.v1 |

---

# Idempotency Rules

Every consumer must handle duplicate events safely.

Recommended approach:

- Store processed event_id.
- Ignore event if already processed.
- Use unique constraints where possible.
- Kafka consumers should retry safely.
- Dead-letter topic should be added later.

---

# Dead Letter Topics

Future dead-letter topics:

| Topic | Purpose |
|---|---|
| auth.events.dlq.v1 | Failed auth event processing |
| message.events.dlq.v1 | Failed message event processing |
| notification.events.dlq.v1 | Failed notification event processing |
| call.events.dlq.v1 | Failed call event processing |

---

# Initial MVP Events

For the first MVP, implement only these events:

- auth.user_registered.v1
- auth.user_logged_in.v1
- conversation.created.v1
- message.created.v1
- message.delivered.v1
- message.read.v1
- realtime.user_connected.v1
- realtime.user_disconnected.v1
- notification.requested.v1
- notification.sent.v1