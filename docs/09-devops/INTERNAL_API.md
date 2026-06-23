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

## User internal API

`UserService.HTTP.Router` (Plug; gated `USER_HTTP_API_ENABLED` + `USER_HTTP_PORT`, default 4103):

| Method + path | In-process call |
|---|---|
| `POST /internal/profiles/current` | `Profiles.get_current_profile/1` |
| `POST /internal/profiles/public` | `Profiles.get_public_profile/1` |
| `POST /internal/profiles/update` | `Profiles.update_current_profile/1` |

Atom-keyed response key set (client adapter rehydrates): `user_id, display_name, avatar_media_id, bio`.
Error atom (preserved): `:profile_invalid`.

## Message internal API (heaviest — 9 routes)

`MessageService.HTTP.Router` (Plug; gated `MESSAGE_HTTP_API_ENABLED` + `MESSAGE_HTTP_PORT`, default 4104):

| Method + path | In-process call |
|---|---|
| `POST /internal/messages/create` | `Messages.create_message/1` |
| `POST /internal/messages/send` | `Messages.send_message/1` |
| `POST /internal/messages/list` | `Messages.list_messages/1` |
| `POST /internal/messages/update` | `Messages.update_message/1` |
| `POST /internal/messages/edit` | `Messages.edit_message/1` |
| `POST /internal/messages/delete` | `Messages.delete_message/1` |
| `POST /internal/timeline/list` | `Timeline.list_messages/1` (the client's `list_timeline`) |
| `POST /internal/receipts/mark_read` | `Receipts.mark_read/1` |
| `POST /internal/receipts/mark_delivered` | `Receipts.mark_delivered/1` |

Atom-keyed responses: message map (`conversation_id, message_id, sender_user_id, message_type, body,
media_id, status, reply_to_message_id, metadata, created_at`), list as `%{conversation_id, messages: [...]}`.
Error atoms (preserved): `:message_invalid`, `:message_forbidden`.

> ⚠️ **Fidelity caveat for the future Message HTTP client adapter:** a message's **`metadata`** is a
> FREE-FORM map (its keys are data — e.g. media `width`/`height` — not a fixed schema) and is
> **string-keyed in-process**. The generic `decode_result/1` atomizes map keys, which would corrupt
> `metadata` (string keys → atoms). The Message client adapter MUST preserve `metadata`'s original
> string keys (skip atomizing that sub-map). The persistence-off placeholder paths carry NO `metadata`,
> so plain Plug.Test round-trips are clean; this only bites the DB path. (Server side is unaffected —
> it only JSON-encodes.)

## Media internal API

`MediaService.HTTP.Router` (Plug; gated `MEDIA_HTTP_API_ENABLED` + `MEDIA_HTTP_PORT`, default 4105;
media-service owns no Repo, so the listener is its only child):

| Method + path | In-process call |
|---|---|
| `POST /internal/media/create_upload` | `Media.create_upload/1` |
| `POST /internal/media/complete_upload` | `Media.complete_upload/1` |
| `POST /internal/media/download_url` | `Media.get_download_url/1` |

Atom-keyed responses: upload → `media_id, object_key, upload_url, expires_at`; download →
`media_id, download_url, expires_at`. Error atom (preserved): `:media_invalid`. (`create_upload`
generates a UUID `media_id`, so it is non-deterministic — fidelity is asserted on the deterministic
error path in tests.)

## HTTP client adapters (caller side) — flip traffic to the network

Each `SharedInfra.*Client` dispatcher selects an adapter from config. Default = the in-process
adapter (in the service app). Setting e.g. `AUTH_CLIENT_ADAPTER=http` flips it to the HTTP adapter,
which lives in **shared_infra** (the gateway/realtime containers depend on shared_infra but NOT on
the service apps post-split).

- **`SharedInfra.HttpClient`** — shared helper all 5 adapters reuse. `post_result/4` / `get_result/3`
  build the request (`AUTH_SERVICE_URL` + path + `x-internal-token` + JSON), apply timeouts (2s connect /
  5s receive, configurable via `:shared_infra, :http_client_connect_timeout`/`_receive_timeout`), and:
  - HTTP **200 + JSON envelope** → `decode_result/1` (domain `{:ok,_}`/`{:error, domain_atom}` — shape-identical to in-process);
  - **transport failure** (connect refused / timeout / non-200 / non-JSON) → `{:error, <unavailable_atom>}`.
  - HTTP lib = OTP `:httpc` (`:inets`). **Req was the intended choice but the package registry was
    unreachable in this environment, so `:httpc` (zero-dep) is used — isolated in this module so Req can
    be swapped in by changing only `HttpClient` once a registry is reachable.**
- **`SharedInfra.AuthClientHttp`** (done) — `@behaviour SharedInfra.AuthClient`; calls the auth internal
  API; `unavailable_atom: :auth_unavailable`. `persistence_enabled?` fails CLOSED (`false`) on transport
  failure (never a truthy error tuple). Config: `AUTH_SERVICE_URL`, `AUTH_CLIENT_ADAPTER=http`.
- **`SharedInfra.ConversationClientHttp`** (done) — `@behaviour SharedInfra.ConversationClient`; calls the
  conversation internal API; `unavailable_atom: :conversation_unavailable`. Atom-keyed conversation/participant
  maps + nested participant lists round-trip via the recursive `decode_result`. Config:
  `CONVERSATION_SERVICE_URL`, `CONVERSATION_CLIENT_ADAPTER=http`.

### Gateway failure mapping (additive)
Transport failure → `{:error, :auth_unavailable}` → the gateway maps it to **HTTP 503** via the new
`ErrorResponse.service_unavailable/2` (same `{error:{code,message,correlation_id}}` envelope, code
`"<svc>.unavailable"`). Added at **every `current_session` call-site** (auth/user/message/conversation/
media controllers) + the auth otp/refresh/logout actions. Existing error-atom clauses are untouched, and
`:auth_unavailable` only occurs when the HTTP adapter is flipped on (default in-process → these clauses
are dead in the default path → zero behavior change). The realtime socket already fails closed on any
auth error (rejects), so no change there.

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
- ✅ User internal HTTP API (`UserService.HTTP.Router`) — built, gated off.
- ✅ Message internal HTTP API (`MessageService.HTTP.Router`, 9 routes) — built, gated off.
- ✅ Media internal HTTP API (`MediaService.HTTP.Router`) — built, gated off. **INTERNAL-API SET COMPLETE (all 5).**
- ⏳ HTTP client adapters (`*ClientHttp`) — flip `SharedInfra.*Client` to network behind a flag. **(next phase)**
- ⏳ Per-service releases / Dockerfiles / compose.
