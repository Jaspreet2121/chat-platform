# Production image for the Next.js web app (chat at /, admin at /admin — one container serves both;
# Caddy routes web.growblic.com + admin.growblic.com here).
#
# NEXT_PUBLIC_* values are INLINED INTO THE JS BUNDLE AT BUILD TIME — they must be passed as
# --build-arg (compose does this via the web service's build.args), not just runtime env.
#
# Build context = apps/web (compose sets it).

# --- deps ---
FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

# --- build ---
FROM node:22-alpine AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .

ARG NEXT_PUBLIC_API_BASE_URL
ARG NEXT_PUBLIC_REALTIME_URL
ENV NEXT_PUBLIC_API_BASE_URL=$NEXT_PUBLIC_API_BASE_URL \
    NEXT_PUBLIC_REALTIME_URL=$NEXT_PUBLIC_REALTIME_URL \
    NEXT_TELEMETRY_DISABLED=1

RUN npm run build

# --- runtime (standalone output: self-contained server.js, no node_modules) ---
FROM node:22-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0

RUN addgroup -S nextjs && adduser -S nextjs -G nextjs
COPY --from=build --chown=nextjs:nextjs /app/.next/standalone ./
COPY --from=build --chown=nextjs:nextjs /app/.next/static ./.next/static
# (no public/ dir in this app — add a COPY for it here if one is created later)
USER nextjs

EXPOSE 3000
CMD ["node", "server.js"]
