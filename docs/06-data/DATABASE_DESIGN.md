# Database Design

## Purpose

This document defines how data is stored across PostgreSQL, ScyllaDB, and Redis.

The platform uses different databases for different workloads.

## Database Responsibility Summary

| Database | Responsibility |
|---|---|
| PostgreSQL | Transactional and relational business data |
| ScyllaDB | High-volume chat message timeline |
| Redis | Temporary fast state, cache, presence, typing, rate limits |

## Important Rule

Each database has a clear responsibility.

PostgreSQL is used for business truth.

ScyllaDB is used for chat timeline and high-write message data.

Redis is used for temporary fast-access state only.

Redis must not be treated as permanent source of truth.

---

# PostgreSQL Design

## Why PostgreSQL

PostgreSQL will store relational and transactional data such as users, tenants, sessions, roles, permissions, conversations, and billing metadata.

## PostgreSQL Data Domains

### Auth Domain

Tables:

- users_auth
- refresh_tokens
- device_sessions
- login_attempts
- verification_codes

Purpose:

- Login identity
- Phone/email verification
- Refresh token rotation
- Device session tracking
- Login security

### User Domain

Tables:

- user_profiles
- user_settings
- user_privacy_settings

Purpose:

- User name
- Avatar
- Bio
- Privacy settings
- App settings

### Tenant Domain

Tables:

- tenants
- workspaces
- tenant_members
- roles
- permissions
- role_permissions

Purpose:

- B2B organizations
- Workspaces
- Team members
- Admin roles
- Permission management

### Conversation Domain

Tables:

- conversations
- conversation_participants
- conversation_settings
- group_profiles

Purpose:

- 1-to-1 conversation metadata
- Group conversation metadata
- Group name
- Group avatar
- Participants
- Participant roles

### Media Domain

Tables:

- media_assets
- media_uploads
- media_access_logs

Purpose:

- Uploaded file metadata
- File owner
- File size
- MIME type
- Storage key
- Secure access logs

### Notification Domain

Tables:

- push_tokens
- notification_preferences
- notification_logs

Purpose:

- Push notification tokens
- User notification settings
- Notification delivery status

### Call Domain

Tables:

- call_sessions
- call_participants
- call_logs

Purpose:

- Audio/video call history
- Call participants
- Missed call tracking
- Call duration

### Moderation Domain

Tables:

- blocked_users
- user_reports
- moderation_cases
- enforcement_actions

Purpose:

- User block list
- User reports
- Abuse cases
- Admin enforcement actions

### Audit Domain

Tables:

- audit_logs

Purpose:

- Admin actions
- Security events
- Login events
- Tenant-level changes

---

# PostgreSQL Initial Tables

## users_auth

Stores authentication identity.

Columns:

| Column | Type | Notes |
|---|---|---|
| id | uuid | Primary key |
| phone_number | text | Nullable, unique |
| email | text | Nullable, unique |
| password_hash | text | Nullable |
| status | text | active, suspended, deleted |
| created_at | timestamptz | Required |
| updated_at | timestamptz | Required |

## user_profiles

Stores public profile data.

Columns:

| Column | Type | Notes |
|---|---|---|
| user_id | uuid | Primary key |
| display_name | text | Required |
| avatar_media_id | uuid | Nullable |
| bio | text | Nullable |
| created_at | timestamptz | Required |
| updated_at | timestamptz | Required |

## device_sessions

Stores per-device sessions.

Columns:

| Column | Type | Notes |
|---|---|---|
| id | uuid | Primary key |
| user_id | uuid | Required |
| device_id | text | Required |
| device_name | text | Nullable |
| platform | text | android, ios, web |
| refresh_token_hash | text | Required |
| last_seen_at | timestamptz | Nullable |
| revoked_at | timestamptz | Nullable |
| created_at | timestamptz | Required |

## tenants

Stores B2B organizations.

Columns:

| Column | Type | Notes |
|---|---|---|
| id | uuid | Primary key |
| name | text | Required |
| slug | text | Unique |
| status | text | active, suspended |
| created_at | timestamptz | Required |
| updated_at | timestamptz | Required |

## tenant_members

Stores organization members.

Columns:

| Column | Type | Notes |
|---|---|---|
| tenant_id | uuid | Required |
| user_id | uuid | Required |
| role_id | uuid | Required |
| status | text | active, invited, removed |
| joined_at | timestamptz | Nullable |
| created_at | timestamptz | Required |

Primary key:

- tenant_id
- user_id

## conversations

Stores conversation metadata.

Columns:

| Column | Type | Notes |
|---|---|---|
| id | uuid | Primary key |
| tenant_id | uuid | Nullable for B2C/C2C |
| type | text | direct, group, business |
| title | text | Nullable |
| avatar_media_id | uuid | Nullable |
| created_by | uuid | Required |
| created_at | timestamptz | Required |
| updated_at | timestamptz | Required |

## conversation_participants

Stores participants of conversations.

Columns:

| Column | Type | Notes |
|---|---|---|
| conversation_id | uuid | Required |
| user_id | uuid | Required |
| role | text | member, admin, owner |
| joined_at | timestamptz | Required |
| left_at | timestamptz | Nullable |
| muted_until | timestamptz | Nullable |

Primary key:

- conversation_id
- user_id

## media_assets

Stores uploaded media metadata.

Columns:

| Column | Type | Notes |
|---|---|---|
| id | uuid | Primary key |
| owner_user_id | uuid | Required |
| conversation_id | uuid | Nullable |
| storage_provider | text | s3, minio |
| bucket | text | Required |
| object_key | text | Required |
| mime_type | text | Required |
| size_bytes | bigint | Required |
| checksum | text | Nullable |
| created_at | timestamptz | Required |

## call_sessions

Stores call sessions.

Columns:

| Column | Type | Notes |
|---|---|---|
| id | uuid | Primary key |
| conversation_id | uuid | Required |
| started_by | uuid | Required |
| call_type | text | audio, video |
| status | text | ringing, active, ended, missed, rejected |
| started_at | timestamptz | Required |
| ended_at | timestamptz | Nullable |

## audit_logs

Stores audit events.

Columns:

| Column | Type | Notes |
|---|---|---|
| id | uuid | Primary key |
| actor_user_id | uuid | Nullable |
| tenant_id | uuid | Nullable |
| action | text | Required |
| target_type | text | Required |
| target_id | text | Nullable |
| metadata | jsonb | Nullable |
| ip_address | text | Nullable |
| user_agent | text | Nullable |
| created_at | timestamptz | Required |

---

# ScyllaDB Design

## Why ScyllaDB

ScyllaDB will store chat message timeline because messages need high write throughput and fast reads by conversation.

## ScyllaDB Query-First Design

ScyllaDB tables should be designed around query patterns.

Main query patterns:

- Get latest messages for a conversation.
- Get older messages before a cursor.
- Get message receipts for a conversation.
- Get reactions for a message.
- Get user conversation inbox later.

## ScyllaDB Keyspace

Keyspace:

chat_messages

Replication strategy:

LocalStrategy for local development.

NetworkTopologyStrategy for production later.

## Table: messages_by_conversation

Purpose:

Store message timeline per conversation.

Query:

Get latest messages in a conversation ordered by message time.

Columns:

| Column | Type | Notes |
|---|---|---|
| conversation_id | uuid | Partition key |
| bucket_date | date | Partition key for large conversations |
| message_id | timeuuid | Clustering key |
| sender_user_id | uuid | Required |
| message_type | text | text, image, video, audio, file, system |
| body | text | Nullable |
| media_id | uuid | Nullable |
| reply_to_message_id | timeuuid | Nullable |
| status | text | active, edited, deleted |
| metadata | map<text,text> | Optional |
| created_at | timestamp | Required |
| edited_at | timestamp | Nullable |
| deleted_at | timestamp | Nullable |

Primary key idea:

- Partition key: conversation_id, bucket_date
- Clustering key: message_id descending

## Table: message_receipts_by_conversation

Purpose:

Store delivery and read receipts.

Columns:

| Column | Type | Notes |
|---|---|---|
| conversation_id | uuid | Partition key |
| message_id | timeuuid | Clustering key |
| user_id | uuid | Clustering key |
| status | text | delivered, read |
| updated_at | timestamp | Required |

## Table: message_reactions_by_message

Purpose:

Store reactions on messages.

Columns:

| Column | Type | Notes |
|---|---|---|
| conversation_id | uuid | Partition key |
| message_id | timeuuid | Partition key |
| user_id | uuid | Clustering key |
| reaction | text | emoji or reaction code |
| created_at | timestamp | Required |

## Table: messages_by_user_inbox

Purpose:

Optional table for fast inbox rendering.

Columns:

| Column | Type | Notes |
|---|---|---|
| user_id | uuid | Partition key |
| last_message_at | timestamp | Clustering key |
| conversation_id | uuid | Required |
| last_message_id | timeuuid | Required |
| last_message_preview | text | Nullable |
| unread_count | int | Required |

---

# Redis Design

## Why Redis

Redis is used for temporary fast state.

## Redis Data Types

### Presence

Key pattern:

presence:user:{user_id}

Value:

- online
- last_seen_at
- active_device_ids

TTL:

60 seconds

### Typing Indicator

Key pattern:

typing:conversation:{conversation_id}:user:{user_id}

Value:

typing

TTL:

5 seconds

### Socket Session

Key pattern:

socket:connection:{connection_id}

Value:

- user_id
- device_id
- connected_at

TTL:

Until disconnect or short expiry

### Rate Limit

Key pattern:

rate_limit:user:{user_id}:send_message

Value:

Counter

TTL:

60 seconds

### OTP Cache

Key pattern:

otp:{purpose}:{phone_or_email}

Value:

Hashed OTP

TTL:

5 minutes

## Redis Rules

- Redis data can expire anytime.
- Redis must not be the only place for critical business data.
- Presence and typing state should be rebuilt from active connections.
- Rate limit data can be reset without breaking core business logic.

---

# Data Consistency Rules

## Strong Consistency Required

Use PostgreSQL for:

- User account
- Tenant membership
- Role assignment
- Conversation membership
- Payment and billing later

## Eventual Consistency Accepted

Use Kafka and async workers for:

- Push notifications
- Search indexing
- Analytics
- Audit fanout
- Offline notification

## High-Volume Timeline

Use ScyllaDB for:

- Message timeline
- Message receipts
- Message reactions

---

# Initial Development Plan

## Phase 1

Use PostgreSQL for auth, users, tenants, conversations.

Use Redis for presence and typing.

Use ScyllaDB for messages.

## Phase 2

Add Kafka events for message.created, message.delivered, message.read.

## Phase 3

Add inbox table and search service.

## Phase 4

Optimize ScyllaDB partitions and add retention policies.
