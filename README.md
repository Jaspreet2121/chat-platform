# Chat Platform

Enterprise-grade B2B, B2C, and C2C communication platform.

## Core Features

- 1-to-1 chat
- Group chat
- Audio call
- Video call
- Media sharing
- Realtime presence
- Typing indicators
- Delivery and read receipts
- B2B organizations
- Admin panel
- Moderation
- Notifications

## Tech Stack

### Frontend
- Nx Monorepo
- React Native / Expo
- Next.js
- TypeScript

### Backend
- Phoenix / Elixir
- Microservices architecture
- PostgreSQL
- ScyllaDB
- Redis
- Kafka

### Infrastructure
- Docker
- Kubernetes later
- GitHub Actions CI for backend checks

## Backend Development

Run the Docker-free backend regression:

```bash
make backend-test
```

Run backend formatting and compile checks:

```bash
make backend-format
make backend-compile
```

Start or stop local infrastructure:

```bash
make infra-up
make infra-down
```

Run opt-in PostgreSQL integration tests after preparing the local
`chat_platform_test` database:

```bash
make backend-test-integration
```

Default CI runs backend dependency install, formatting check, compile with
warnings as errors, and Docker-free tests. PostgreSQL integration tests remain
opt-in locally until a dedicated CI database setup is wired.

The Redis-backed rate limiter and MinIO/S3 presigned URL adapters are available
behind config. ScyllaDB message storage has a shared client boundary, with live
driver execution still deferred where documented; normal backend tests do not
require those services.

## Web Frontend

The first web MVP lives in `apps/web` and uses Next.js, TypeScript, App Router,
and Tailwind CSS.

Install and run it locally:

```bash
cd apps/web
cp .env.example .env.local
npm install
npm run dev
```

Or use the root helpers:

```bash
make web-dev
make web-lint
make web-build
```

Configure the web app with:

```env
NEXT_PUBLIC_API_BASE_URL=http://localhost:4000
NEXT_PUBLIC_REALTIME_URL=ws://localhost:4000/socket
```

The MVP keeps auth tokens in browser `localStorage` for now. This is convenient
for early wiring, but not production-final.

## Current Phase

Phase 0: Documentation and architecture planning.
