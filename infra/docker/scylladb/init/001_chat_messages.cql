-- Initial ScyllaDB schema for chat message timelines.

CREATE KEYSPACE IF NOT EXISTS chat_messages
WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1}
AND durable_writes = true;

USE chat_messages;

CREATE TABLE IF NOT EXISTS messages_by_conversation (
  conversation_id uuid,
  bucket_date date,
  message_id timeuuid,
  sender_user_id uuid,
  message_type text,
  body text,
  media_id uuid,
  reply_to_message_id timeuuid,
  status text,
  metadata map<text, text>,
  created_at timestamp,
  edited_at timestamp,
  deleted_at timestamp,
  PRIMARY KEY ((conversation_id, bucket_date), message_id)
) WITH CLUSTERING ORDER BY (message_id DESC);

CREATE TABLE IF NOT EXISTS message_receipts_by_conversation (
  conversation_id uuid,
  message_id timeuuid,
  user_id uuid,
  status text,
  updated_at timestamp,
  PRIMARY KEY (conversation_id, message_id, user_id)
) WITH CLUSTERING ORDER BY (message_id DESC, user_id ASC);

CREATE TABLE IF NOT EXISTS message_reactions_by_message (
  conversation_id uuid,
  message_id timeuuid,
  user_id uuid,
  reaction text,
  created_at timestamp,
  PRIMARY KEY ((conversation_id, message_id), user_id)
);

CREATE TABLE IF NOT EXISTS messages_by_user_inbox (
  user_id uuid,
  last_message_at timestamp,
  conversation_id uuid,
  last_message_id timeuuid,
  last_message_preview text,
  unread_count int,
  PRIMARY KEY (user_id, last_message_at, conversation_id)
) WITH CLUSTERING ORDER BY (last_message_at DESC, conversation_id ASC);

