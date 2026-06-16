# AI Context

## Project Name

chat-platform

## Product Goal

Build an enterprise-grade chatting platform that supports B2B, B2C, and C2C communication.

The platform should support WhatsApp-like features including chat, group chat, audio calls, video calls, media sharing, presence, typing indicators, delivery status, read receipts, notifications, and admin controls.

## Current Phase

Phase 0: Documentation and architecture planning.

## Tech Stack

### Frontend

- Nx monorepo
- React Native / Expo for mobile app
- Next.js for web app, admin dashboard, and business portal
- TypeScript

### Backend

- Phoenix / Elixir
- Microservices architecture
- Phoenix Channels for realtime communication
- Phoenix Presence for online/offline state

### Databases and Infrastructure

- PostgreSQL for transactional data
- ScyllaDB for high-volume chat messages
- Redis for cache, presence, typing indicators, sessions, rate limits
- Kafka for event streaming
- Docker for local development
- Kubernetes later for production deployment

## Main Applications

### Frontend Apps

- mobile
- web
- admin
- business-portal

### Backend Services

- api-gateway
- auth-service
- user-service
- tenant-service
- conversation-service
- message-service
- realtime-gateway
- notification-service
- media-service
- call-signaling-service
- moderation-service
- audit-service

## Architecture Rules

- Frontend must never connect directly to databases.
- All external frontend requests must go through API Gateway.
- Realtime communication should use Phoenix Channels.
- PostgreSQL is the source of truth for users, tenants, conversations, roles, permissions, and billing.
- ScyllaDB is the source of truth for message timelines.
- Redis is not a source of truth. It is only for temporary fast state.
- Kafka events must be versioned.
- Every important architecture decision must be added to Decision Log.
- Every completed session must update Session Log.

## Current Next Step

Create initial documentation files and define the project roadmap.
