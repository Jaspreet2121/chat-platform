# Message Service

Owns high-volume message timeline behavior.

Current scope:

- OTP application shell.
- Boundary modules for messages, receipts, reactions, timeline, and permissions.
- ScyllaDB and Kafka configuration placeholders.
- Message API skeletons return placeholders only. No ScyllaDB reads/writes, authorization logic, or Kafka publishing yet.

Future storage:

- ScyllaDB `chat_messages` keyspace.
- `messages_by_conversation`
- `message_receipts_by_conversation`
- `message_reactions_by_message`

Future events:

- `message.created.v1`
- `message.edited.v1`
- `message.deleted.v1`
- `message.delivered.v1`
- `message.read.v1`
- `message.reaction_added.v1`
