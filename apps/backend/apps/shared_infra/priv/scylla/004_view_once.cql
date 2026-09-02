-- 115 (Scylla side): view_once on the message row.
--
-- A NATIVE BOOLEAN, not a metadata key. metadata is map<text,text> here, so a jsonb `true` from the
-- Postgres side would arrive as the STRING "true" and the two stores would disagree about a flag
-- that gates media access. That divergence class has already shipped in this keyspace (ISO strings
-- against `date`, nested maps against map<text,text>) — a real column is the fix, not a convention.
--
-- view_once_opens has NO Scylla counterpart, deliberately: media authz is a Postgres read (the
-- media_download_allowed oracle and the view-once gate run against the same Repo), so mirroring
-- opens here would create a second source of truth for an authorization decision with no reader.
--
-- IDEMPOTENCY: Scylla 5.4 REJECTS `ALTER ... ADD IF NOT EXISTS` (SyntaxException — see 003). This
-- file is therefore NOT self-idempotent; the loader treats "conflicts with an existing column" as
-- already-applied. Kept in its own numbered file so that tolerance stays narrow, per 003's rule.

USE chat_messages;

ALTER TABLE messages_by_conversation ADD view_once boolean;
