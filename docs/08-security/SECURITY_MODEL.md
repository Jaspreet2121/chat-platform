# Security Model

## Purpose

This document defines the security architecture for chat-platform.

The platform supports B2B, B2C, and C2C communication, so security must be designed from day one.

## Core Security Principles

- Secure by default.
- Least privilege access.
- Every request must be authenticated where required.
- Every business action must be authorized.
- Tenant data must be isolated.
- Redis must not store permanent sensitive data.
- Secrets must never be committed to Git.
- All APIs must be rate-limited.
- All important actions must be auditable.
- Sensitive data must be encrypted in transit and at rest.
- Every service must validate input.

---

# Authentication

## Auth Methods

Initial authentication methods:

- Phone OTP login
- Email OTP login later
- Password login later
- Social login later
- Enterprise SSO later

## Token Strategy

Use:

- Short-lived access token
- Long-lived refresh token
- Refresh token rotation
- Per-device session tracking

## Access Token

Access token should contain:

- user_id
- device_id
- tenant_id if tenant context is active
- roles
- permissions summary
- issued_at
- expires_at

Access token lifetime:

- 15 minutes recommended

## Refresh Token

Refresh token should be:

- Stored hashed in PostgreSQL
- Rotated on every refresh
- Revocable per device
- Linked to device session

Refresh token lifetime:

- 30 days for mobile
- 7 days for web initially

## Device Sessions

Each login creates or updates a device session.

Track:

- user_id
- device_id
- platform
- device_name
- refresh_token_hash
- last_seen_at
- revoked_at
- created_at

---

# Authorization

## Authorization Model

Use a hybrid model:

- RBAC for B2B organizations
- User-level permissions for C2C/B2C
- System-level permissions for internal admin

## Role Types

Initial roles:

- consumer_user
- business_member
- business_admin
- business_owner
- support_agent
- super_admin

## Tenant Authorization

Every B2B request must check:

- Is user part of tenant?
- Is user active in tenant?
- Does user have required role?
- Does user have required permission?

## Conversation Authorization

Before user accesses conversation:

- User must be a participant.
- User must not have left the conversation.
- User must not be blocked from the conversation.
- For B2B conversation, user must belong to the tenant if tenant-scoped.

## Message Authorization

Before sending message:

- User must be authenticated.
- User must be participant of conversation.
- Conversation must be active.
- Sender must not be blocked.
- Sender must pass rate limit checks.

Before reading messages:

- User must be participant of conversation.
- User must have access from joined_at time.
- User should not read messages before membership if policy disallows it.

**Implemented (flag-gated):** HTTP message **create** and **list** now enforce conversation
membership at the API Gateway (`message_controller.ex` `authorize_membership/2`), reusing the
same `ConversationService.Conversations.get_conversation/1` check the realtime channel-join
path uses. A non-participant receives `403 message.forbidden`. Enforcement is active when
conversation persistence is on (`CONVERSATION_DB_BACKED`); with it off, the placeholder
`get_conversation` returns `{:ok}` and no membership data exists, so the local-dev path is
unchanged. Still placeholder (NOT enforced): block-state and tenant checks for messaging;
`MessageService.Permissions.authorize/1` remains a pass-through.

Before editing or deleting a message:

- Only the original sender (author) may edit or delete the message. **Implemented**:
  enforced at the shared `MessageService.Messages.update_message`/`delete_message`
  boundary (`apps/backend/apps/message_service/lib/message_service/messages.ex`), so
  both the HTTP `PATCH`/`DELETE` path and the realtime `message:update`/`message:delete`
  channel path inherit one check. A non-author receives a forbidden response in the
  standard error envelope (HTTP: `403 message.forbidden`, as already documented in the
  message-service contract; channel: `realtime.forbidden`).
- Still placeholder (NOT yet enforced): participant/tenant/block checks for edit/delete
  remain TODO (`MessageService.Permissions.authorize/1` is a pass-through). Admin-override
  delete (vs. author-only) is a separate future concern.

---

# Tenant Isolation

## Rule

Tenant data must be isolated at the application layer and database query layer.

## Required Checks

Every tenant-scoped table must include tenant_id where applicable.

Every tenant-scoped query must filter by tenant_id.

Examples:

- tenant_members
- conversations
- audit_logs
- billing_accounts
- roles
- permissions

## B2C and C2C

For B2C/C2C conversations:

- tenant_id can be null.
- Access must be controlled by conversation_participants.

---

# API Security

## Public API Rules

- All public APIs go through API Gateway.
- Use HTTPS in production.
- Validate all input.
- Use request size limits.
- Use rate limits.
- Use authentication middleware.
- Use authorization middleware.
- Use structured error responses.

## Internal API Rules

- Internal APIs are not exposed publicly.
- Services should authenticate internal requests.
- Use service-to-service tokens initially.
- Use mTLS later in Kubernetes.
- Validate internal requests too.

## API Versioning

Public APIs must be versioned:

Example:

- /api/v1/auth/login
- /api/v1/users/me
- /api/v1/conversations
- /api/v1/messages

Breaking changes require new API version.

---

# Realtime Security

## Phoenix Channel Authentication

Every WebSocket connection must authenticate using access token.

On connection:

- Verify token signature.
- Verify token expiry.
- Verify device session.
- Assign user_id and device_id to socket.

**Implemented (flag-gated) + fail-closed.** Trustworthy socket identity requires BOTH
`REALTIME_AUTH_DB_BACKED=true` AND `AUTH_SESSION_DB_BACKED=true`: the socket validates
the access token through the same `AuthService.Sessions.current_session/1` the HTTP
bearer path uses (signature, expiry, claims, issuer/audience, active non-revoked device
session, active user). The socket now **fails closed**: if socket auth is enabled but the
session layer is not genuinely DB-backed (i.e. `AUTH_SESSION_DB_BACKED` is off), the
connection is **rejected** rather than accepting the unverified placeholder identity
(`RealtimeGateway.UserSocket` `require_db_backed_sessions`). With socket auth OFF (the
local-dev default) the socket assigns a placeholder identity and trusts a client-provided
`user_id` — so production MUST run with both flags on.

## Channel Join Authorization

Before joining conversation channel:

- Check user is participant.
- Check conversation is active.
- Check user is not blocked.
- Check tenant access if tenant conversation.

Channel topic format:

- conversation:{conversation_id}
- user:{user_id}
- call:{call_id}

## Realtime Event Rules

Clients can send:

- typing_started
- typing_stopped
- message_read
- call_signal

Clients cannot directly broadcast:

- message_created
- message_delivered
- notification_sent

Server must control trusted events.

---

# Rate Limiting

## Purpose

Prevent spam, abuse, brute force, and infrastructure overload.

## Initial Rate Limits

Auth:

- OTP request: 5 per 15 minutes per phone/email
- Login attempts: 10 per 15 minutes per account
- Refresh token: 60 per hour per device

Messaging:

- Send message: 60 per minute per user
- Create conversation: 20 per hour per user
- Upload media: 100 per hour per user

Realtime:

- Typing event: 30 per minute per conversation
- Channel join: 100 per minute per user

Admin:

- Sensitive admin action: stricter audit and rate limits

## Storage

Use Redis for rate limit counters.

Redis key examples:

- rate_limit:otp:{phone}
- rate_limit:login:{user_id}
- rate_limit:message:{user_id}
- rate_limit:upload:{user_id}

---

# Data Protection

## Encryption In Transit

Production must use:

- HTTPS for public APIs
- WSS for WebSocket
- TLS for internal services later
- TLS for database connections later

## Encryption At Rest

Required for:

- PostgreSQL storage
- ScyllaDB storage
- Object storage
- Backups

## Sensitive Data

Sensitive data includes:

- OTP
- Refresh tokens
- Password hashes
- Personal data
- IP addresses
- User agent
- Media files
- Admin audit logs

## Rules

- Never store raw OTP.
- Never store raw refresh token.
- Never log passwords, OTPs, access tokens, or refresh tokens.
- Hash refresh tokens before saving.
- Hash OTP before saving.
- Use secure password hashing when password login is added.

---

# Media Security

## Upload Rules

- Client requests upload URL from media-service.
- media-service validates user and file type.
- media-service creates media record.
- Client uploads file to object storage.
- Client confirms upload.
- media-service verifies upload and publishes media.upload_completed.v1.

## Download Rules

- Client requests secure media URL.
- media-service checks conversation access.
- media-service returns short-lived signed URL.
- Signed URL must expire quickly.

## Allowed File Types Initially

- image/jpeg
- image/png
- image/webp
- video/mp4
- audio/mpeg
- audio/mp4
- application/pdf

## Future Security

- Virus scanning
- NSFW detection
- File size limits by plan
- Media retention policies

---

# Moderation and Abuse Prevention

## User Controls

Users should be able to:

- Block user
- Report user
- Report message
- Leave group
- Mute conversation

## Admin Controls

Admins should be able to:

- View reports
- Review reported messages
- Suspend user
- Remove abusive content
- View audit trail
- Rate-limit abusive accounts

## Abuse Events

Important events:

- moderation.user_blocked.v1
- moderation.report_created.v1
- moderation.action_taken.v1

---

# Audit Logging

## Must Audit

- Login
- Logout
- Failed login attempts
- Device registration
- Role assignment
- Tenant member addition
- Tenant member removal
- Admin actions
- User suspension
- Message deletion by admin
- Security-sensitive configuration changes

## Audit Log Fields

- audit_log_id
- actor_user_id
- tenant_id
- action
- target_type
- target_id
- metadata
- ip_address
- user_agent
- created_at

## Audit Rules

- Audit logs should be append-only.
- Audit logs should not be editable by normal admins.
- Sensitive values should be masked.
- Audit logs should be tenant-filtered in B2B admin views.

---

# Secrets Management

## Local Development

Use:

- .env
- .env.example

Never commit:

- .env
- private keys
- API keys
- database passwords
- JWT secrets
- cloud credentials

## Production Later

Use:

- Cloud secrets manager
- Kubernetes secrets initially
- Vault later if needed

---

# Logging Rules

Logs must not include:

- Passwords
- OTPs
- Refresh tokens
- Access tokens
- Private keys
- Full media signed URLs
- Payment card data later

Logs may include:

- request_id
- correlation_id
- user_id
- tenant_id
- route
- status_code
- latency
- error_code

---

# Security Headers

For web apps and API responses:

- Content-Security-Policy
- X-Content-Type-Options
- X-Frame-Options
- Referrer-Policy
- Strict-Transport-Security in production

---

# Future Security Features

## End-to-End Encryption

Future feature for private chats.

Will require:

- Per-device identity keys
- Session keys
- Message encryption on client
- Server stores encrypted payload only
- Key backup strategy
- Multi-device support design

## Enterprise Security

Future B2B features:

- SSO
- SAML
- SCIM provisioning
- Data retention policies
- Legal hold
- Compliance exports
- Advanced audit logs
- IP allowlist

---

# MVP Security Checklist

Before first MVP release:

- Access token implemented
- Refresh token rotation implemented
- Device session tracking implemented
- OTP rate limit implemented
- Message send rate limit implemented
- Conversation access check implemented
- WebSocket auth implemented
- Channel join authorization implemented
- Media signed URL authorization implemented
- Audit log for login implemented
- Audit log for admin actions implemented
- .env excluded from Git