# Service Catalog

## Purpose

This document defines all backend services, their responsibilities, owned data, and communication patterns.

## Service List

---

## 1. api-gateway

### Responsibility

External API entry point for mobile app, web app, admin dashboard, and business portal.

### Owns Data

No business data.

### Talks To

- auth-service
- user-service
- tenant-service
- conversation-service
- message-service
- media-service
- notification-service

### Exposes

- Public REST APIs
- API versioning
- Request validation
- Rate limiting
- Authentication middleware

---

## 2. auth-service

### Responsibility

Handles authentication and session management.

### Owns Data

PostgreSQL:

- users_auth
- refresh_tokens
- device_sessions
- login_attempts
- verification_codes

### Main Features

- Signup
- Login
- Logout
- Refresh token
- OTP verification
- Device session management
- Password login later
- SSO later

### Publishes Events

- auth.user_registered.v1
- auth.user_logged_in.v1
- auth.user_logged_out.v1
- auth.device_registered.v1

---

## 3. user-service

### Responsibility

Handles user profile and user settings.

### Owns Data

PostgreSQL:

- user_profiles
- user_settings
- user_privacy_settings

### Main Features

- Get profile
- Update profile
- Upload avatar metadata
- User privacy settings
- Search users later

### Publishes Events

- user.profile_created.v1
- user.profile_updated.v1
- user.avatar_updated.v1

---

## 4. tenant-service

### Responsibility

Handles B2B organizations, workspaces, members, roles, and permissions.

### Owns Data

PostgreSQL:

- tenants
- workspaces
- tenant_members
- roles
- permissions
- role_permissions

### Main Features

- Create organization
- Invite member
- Assign role
- Remove member
- Tenant-level settings
- Enterprise SSO later

### Publishes Events

- tenant.created.v1
- tenant.member_added.v1
- tenant.member_removed.v1
- tenant.role_assigned.v1

---

## 5. conversation-service

### Responsibility

Handles conversation metadata and participants.

### Owns Data

PostgreSQL:

- conversations
- conversation_participants
- conversation_settings
- group_profiles

### Main Features

- Create 1-to-1 conversation
- Create group conversation
- Add participant
- Remove participant
- Update group profile
- Mute conversation
- Archive conversation

### Publishes Events

- conversation.created.v1
- conversation.participant_added.v1
- conversation.participant_removed.v1
- conversation.updated.v1

---

## 6. message-service

### Responsibility

Handles message creation, message timeline, receipts, edits, deletes, reactions.

### Owns Data

ScyllaDB:

- messages_by_conversation
- messages_by_user
- message_receipts_by_conversation
- message_reactions_by_message

PostgreSQL optional metadata:

- message_sequences
- message_policy_metadata

### Main Features

- Send text message
- Send media message
- Edit message
- Delete message
- Message list
- Delivery receipt
- Read receipt
- Reactions later

### Publishes Events

- message.created.v1
- message.edited.v1
- message.deleted.v1
- message.delivered.v1
- message.read.v1
- message.reaction_added.v1

---

## 7. realtime-gateway

### Responsibility

Handles WebSocket communication using Phoenix Channels and Phoenix Presence.

### Owns Data

Redis temporary state:

- socket sessions
- presence state
- typing state

### Main Features

- Client WebSocket connection
- Join conversation channel
- Leave conversation channel
- Send typing event
- Receive message event
- Presence tracking
- Call signaling channel

### Consumes Events

- message.created.v1
- message.edited.v1
- message.deleted.v1
- notification.realtime_requested.v1

### Publishes Events

- realtime.user_connected.v1
- realtime.user_disconnected.v1
- realtime.typing_started.v1
- realtime.typing_stopped.v1
- message.delivered.v1
- message.read.v1

---

## 8. notification-service

> ✅ **EXISTS (2026-06-18)** — the FIRST of the 5 documented-only services to be built
> (`apps/backend/apps/notification_service`). First slice: an idempotent consumer that turns
> each `message.created.v1` into ONE notification record (`type: "message_created"`), deduped
> via notification-service's OWN ledger `notification_processed_events` keyed `(consumer, event_id)`.
> Flag-gated by `NOTIFICATION_CONSUMER_ENABLED` (default off; nothing connects at boot).
> **NOT yet built:** recipient fan-out (one record per participant — needs ConversationService
> participant data), push/email/SMS delivery, `notification_preferences`/`push_tokens` tables,
> and `notification.sent.v1`/`notification.failed.v1` publishing.

### Responsibility

Handles push, email, and SMS notifications.

### Owns Data

PostgreSQL:

- notification_preferences
- push_tokens
- notification_logs

### Main Features

- Push notification
- Email notification
- SMS notification
- Notification preferences
- Missed call notification
- Offline message notification

### Consumes Events

- message.created.v1
- call.started.v1
- call.missed.v1
- tenant.member_invited.v1

### Publishes Events

- notification.sent.v1
- notification.failed.v1

---

## 9. media-service

### Responsibility

Handles media upload, media metadata, and secure media access.

### Owns Data

PostgreSQL:

- media_assets
- media_uploads
- media_access_logs

Object Storage:

- images
- videos
- audio files
- documents

### Main Features

- Generate upload URL
- Confirm upload
- Store metadata
- Generate secure download URL
- Thumbnail generation later
- Virus scan later

### Publishes Events

- media.upload_requested.v1
- media.upload_completed.v1
- media.processing_completed.v1

---

## 10. call-signaling-service

### Responsibility

Handles audio/video call signaling.

### Owns Data

PostgreSQL:

- call_sessions
- call_participants
- call_logs

### Main Features

- Start call
- Ring participant
- Accept call
- Reject call
- End call
- Missed call
- WebRTC signaling
- LiveKit integration later

### Publishes Events

- call.started.v1
- call.ringing.v1
- call.accepted.v1
- call.rejected.v1
- call.ended.v1
- call.missed.v1

---

## 11. moderation-service

### Responsibility

Handles abuse reports, blocking, spam control, and moderation workflows.

### Owns Data

PostgreSQL:

- blocked_users
- user_reports
- moderation_cases
- enforcement_actions

### Main Features

- Block user
- Report user
- Review report
- Suspend user
- Rate-limit suspicious activity

### Publishes Events

- moderation.user_blocked.v1
- moderation.report_created.v1
- moderation.action_taken.v1

---

## 12. audit-service

### Responsibility

Stores security-sensitive and admin action logs.

### Owns Data

PostgreSQL:

- audit_logs

### Main Features

- Login audit
- Admin action audit
- Tenant action audit
- Security event audit

### Consumes Events

- auth.user_logged_in.v1
- tenant.role_assigned.v1
- moderation.action_taken.v1
- call.started.v1
- message.deleted.v1
