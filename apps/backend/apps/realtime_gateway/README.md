# Realtime Gateway

WebSocket boundary for Phoenix Channels and future Phoenix Presence.

Current scope:

- OTP application shell.
- Redis and Kafka configuration placeholders.
- Phoenix socket mounted by API Gateway at `/socket`.
- Channel skeletons for `conversation:{conversation_id}`, `user:{user_id}`, and `call:{call_id}`.
- Placeholder join authorization only.
- No real JWT authentication, Redis Presence connection, Kafka consumption, or Kafka publishing yet.

Future responsibilities:

- Authenticate socket connections.
- Join `conversation:{conversation_id}`, `user:{user_id}`, and `call:{call_id}` topics.
- Track presence and typing through Redis-backed temporary state.
- Consume message and conversation events for realtime fanout.

Run tests from `apps/backend`:

```bash
mix test apps/realtime_gateway/test
```
