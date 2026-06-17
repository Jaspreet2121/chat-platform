# Conversation Service

Owns conversation metadata, participants, settings, and group profiles.

Current scope:

- OTP application shell.
- Boundary modules for conversations, participants, groups, and permissions.
- PostgreSQL repo placeholder for conversation tables.
- Repo connections are not started yet; this foundation should boot without requiring database access.
- Conversation API skeletons return placeholders only. No database writes, authorization logic, or Kafka publishing yet.

Future events:

- `conversation.created.v1`
- `conversation.participant_added.v1`
- `conversation.participant_removed.v1`
- `conversation.updated.v1`
