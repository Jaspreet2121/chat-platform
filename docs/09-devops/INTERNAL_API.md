# Internal service-to-service HTTP API

The microservices split gives each backend service an **internal HTTP API** so the edge apps
(api_gateway, realtime_gateway) — which already route through `SharedInfra.*Client` dispatchers —
can call services over the network once the HTTP client adapters land. This doc is the contract
every service's internal API and every HTTP client adapter MUST follow. **Auth is the template
(built first); the other 4 services copy it.**

## Two envelopes — never conflate

1. **PUBLIC (user-facing)** — `ApiGatewayWeb.ErrorResponse` (`{error: {code, message, correlation_id}}`
   + HTTP status). Gateway-only; **unchanged**; services never produce it.
2. **INTERNAL (service↔service)** — `SharedInfra.InternalApi`. Round-trips the in-process result so
   the HTTP client adapter reconstructs the EXACT shape the in-process adapter returns. **Error ATOMS
   are preserved** (the gateway pattern-matches on them, e.g. `{:error, :otp_invalid}`).

## Result-envelope wire contract

`SharedInfra.InternalApi.encode_result/1` (server) ⇄ `decode_result/1` (client adapter):

| In-process result | Wire JSON | Decoded back to |
|---|---|---|
| `{:ok, map}` | `{"ok": <map>}` | `{:ok, map}` (keys rehydrated to atoms) |
| `{:error, atom}` | `{"error": "<atom_name>"}` | `{:error, atom}` (`String.to_existing_atom/1`) |
| bare value (e.g. boolean) | `{"result": <value>}` | the value |

- **All internal responses are HTTP 200** — the ok/error is a DOMAIN result in the body, not a
  transport error. Transport-auth failure is **401** (see TokenPlug). Unknown route → **404**.
- **Key rehydration:** JSON stringifies map keys; `decode_result/1` converts them back via
  `String.to_existing_atom/1` (the atoms exist in the loaded service code), recursively for nested
  maps; an unknown key/atom falls back to the string (never crashes).

### current_session key convention (atom-keyed map — the sharpest fidelity case)

The gateway reads `session.user_id` (atom access), so the client adapter must rehydrate these exact
keys. `current_session` returns a map with **these keys**:

```
user_id, session_id, device_id, platform, issued_at, expires_at
```

(Source: `AuthService.Sessions` `session_response/2` + `placeholder_session_response/0`.) Any service
returning atom-keyed maps must likewise document its key set here as it is built.

## Auth internal API (the template)

`AuthService.HTTP.Router` (Plug, **not** Phoenix — internal APIs are a few JSON routes):

| Method + path | In-process call | Body |
|---|---|---|
| `POST /internal/sessions/current` | `Sessions.current_session/1` | `{"authorization": "Bearer …"}` |
| `GET  /internal/sessions/persistence_enabled` | `Sessions.persistence_enabled?/0` | — |
| `POST /internal/otp/request` | `OTP.request_otp/1` | `{"phone_number","purpose",…}` |
| `POST /internal/otp/verify` | `OTP.verify_otp/1` | `{"otp_request_id","phone_number","device_id","otp"\|"otp_code"}` |
| `POST /internal/tokens/refresh` | `Tokens.refresh/1` | `{"refresh_token"}` |
| `POST /internal/tokens/revoke` | `Tokens.revoke/1` | `{"refresh_token"}` |

## Conversation internal API

`ConversationService.HTTP.Router` (Plug; gated `CONVERSATION_HTTP_API_ENABLED` + `CONVERSATION_HTTP_PORT`, default 4102):

| Method + path | In-process call |
|---|---|
| `POST /internal/conversations/create` | `Conversations.create_conversation/1` |
| `POST /internal/conversations/list` | `Conversations.list_conversations/1` |
| `POST /internal/conversations/get` | `Conversations.get_conversation/1` |
| `POST /internal/participants/add` | `Participants.add_participant/1` |
| `POST /internal/participants/remove` | `Participants.remove_participant/1` |

**Atom-keyed responses (client adapter must rehydrate these key sets):**
- create → `conversation_id, tenant_id, type, title, created_by, participant_user_ids, created_at`
- list → `%{conversations: [<summary maps>]}`
- get → conversation detail + `participants: [%{user_id, role, joined_at, left_at}]`
- add_participant → `conversation_id, user_id, role, joined_at`
- remove_participant → `conversation_id, user_id, removed, left_at`

**Error atoms (preserved):** `:conversation_invalid`, `:conversation_not_found`, `:conversation_forbidden`,
`:participant_invalid`, `:participant_forbidden`, `:participant_already_exists`, `:participant_not_found`,
`:participant_owner_remove_forbidden`. (`decode_result` rebuilds these via `String.to_existing_atom/1`,
recursing into nested maps/lists.)

## Transport auth (NEW security surface)

`SharedInfra.InternalApi.TokenPlug` requires the `x-internal-token` header to match
`:shared_infra, :internal_api_token` (`INTERNAL_API_TOKEN` env), constant-time compare. **Fails
closed** — if no token is configured, every request is rejected (401). Intended to run on a
**private network** (Fly 6PN / docker network), never publicly exposed; the token is defense in depth.
Treat this as a genuinely new attack surface.

## Listener gating (Docker-free preserved)

Each service's listener is a flag-gated `Plug.Cowboy` child started ONLY under its flag — Auth:
`AUTH_HTTP_API_ENABLED` (+ `AUTH_HTTP_PORT`, default 4101). **Default off** → the umbrella boot and
plain `mix test` start NO listener (verified: `AuthService.Supervisor` children `== []` in test env).

## Testing

Drive the router via `Plug.Test` (synthetic conn — no listener/port/network) → plain/Docker-free for
the persistence-off (placeholder) paths; Repo-needing paths are `postgres_integration`. The
encode/decode round-trip + TokenPlug are unit-tested in `SharedInfra.InternalApiTest`.

## Status

- ✅ Auth internal HTTP API (server side), `SharedInfra.InternalApi` + `TokenPlug` — built, gated off.
- ✅ Conversation internal HTTP API (`ConversationService.HTTP.Router`) — built, gated off.
- ⏳ User / Message / Media internal APIs — copy this template.
- ⏳ HTTP client adapters (`*ClientHttp`) — flip `SharedInfra.*Client` to network behind a flag.
- ⏳ Per-service releases / Dockerfiles / compose.
