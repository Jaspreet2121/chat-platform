# Chat Platform Web

Next.js + TypeScript web MVP for the chat platform.

## Setup

```bash
cd apps/web
cp .env.example .env.local
npm install
npm run dev
```

The app expects the API Gateway and realtime socket to be reachable through:

```env
NEXT_PUBLIC_API_BASE_URL=http://localhost:4000
NEXT_PUBLIC_REALTIME_URL=ws://localhost:4000/socket
```

## Scripts

```bash
npm run dev
npm run lint
npm run typecheck
npm run build
```

The MVP stores access and refresh tokens in browser `localStorage`. That keeps
the first frontend slice simple, but it is not the production-final session
storage model.
