# Production Deploy Runbook — single EC2 (Ubuntu, Docker, 7.6 GB / 2 vCPU / 35 GB)

Deploys the microservices stack via `docker-compose.prod.yml`. **HTTP-on-IP first, HTTPS-on-domain later.**
Legend: 🟦 = do in the **AWS console**; 🖥️ = do **on the server**.

The stack fits 7.6 GB comfortably (no ScyllaDB; Kafka heap capped; per-service `mem_limit`s). Rough
budget: postgres 768m · 5 core services 384m each · gateway 512m · kafka 1g · redis 256m · minio 512m ·
notification 384m ≈ **5.4 GB with Kafka, ~4 GB without** — leaving headroom for OS/Docker.

---

## 0. 🟦 Security group (do this FIRST, in AWS)
Inbound rules — allow **only**:
- **22** (SSH) — ideally from your IP only.
- **80** (HTTP) and **443** (HTTPS) — for Caddy (443 needed for TLS; 80 also for the ACME challenge).

Do **NOT** open: `4000` (gateway — Caddy fronts it; not host-published at all), `5432` (postgres), `6379`
(redis), `9000/9001` (minio), `9092/9094` (kafka). These stay internal. Caddy comes up with the stack, so
there is no "pre-Caddy" phase — the public entrypoint is always :80 (and :443 in phase 2).

---

## 1. 🖥️ Server prep — swap (important for the build)
Building 7 Elixir releases on 2 vCPU / 7.6 GB can exhaust RAM. Add a 4 GB swapfile first:
```bash
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -h   # confirm swap is active
```

## 2. 🖥️ Get the code
```bash
git clone <your-repo-url> chat-platform && cd chat-platform
# (later updates: git pull)
```

## 3. 🖥️ Configure `.env`
```bash
cp .env.prod.example .env
# generate fresh secrets:
for v in INTERNAL_API_TOKEN TOKEN_SECRET OTP_SECRET POSTGRES_PASSWORD MINIO_ROOT_PASSWORD; do
  echo "$v=$(openssl rand -hex 32)"
done
echo "SECRET_KEY_BASE=$(openssl rand -hex 64)"
echo "MINIO_ROOT_USER=chatmedia"   # any non-default name
# paste those into .env, then set:
#   PHX_HOST=<EC2_PUBLIC_IP>   CORS_ORIGIN=http://<EC2_PUBLIC_IP>   MINIO_PUBLIC_ENDPOINT=http://<EC2_PUBLIC_IP>:9000
#   WEB_ORIGIN=   (leave empty for the IP smoke test)
# and the SMS_* values (SMS_PROVIDER=smsgatewayhub + your DLT keys) to text real users.
```
The `${VAR:?...}` guards mean compose **won't start** if a required secret is missing — that's intended.

## 4. 🖥️ Build the images (2-vCPU-safe)
Build sequentially so the box doesn't OOM (with swap this is the safe path):
```bash
for svc in postgres auth conversation user message media notification gateway; do
  docker compose -f docker-compose.prod.yml build "$svc"
done
# (postgres/kafka/redis/minio are pulled, not built)
```

## 5. 🖥️ Bring it up (phase 1 — Kafka OFF, Caddy on :80)
One command brings up the whole stack **including Caddy**, with the Kafka trio excluded by default (it's
behind the `kafka` compose profile) and `.env` has the publish flags `false`:
```bash
docker compose -f docker-compose.prod.yml up -d
```
This starts: postgres, redis, minio (+minio-init), auth, conversation, user, message, media, gateway, and
**caddy** (public on :80). Kafka/kafka-init/notification do NOT start.

_Enable Kafka later (push notifications):_ set `KAFKA_PUBLISH_ENABLED=true` + `CONVERSATION_PUBLISH_ENABLED=true`
in `.env`, then `docker compose -f docker-compose.prod.yml --profile kafka up -d`. It works (KAFKA_BROKERS
is honored at runtime). Core chat/realtime/login/media/admin are unaffected by this toggle.

## 6. 🖥️ Verify
```bash
docker compose -f docker-compose.prod.yml ps        # all Up / healthy (no kafka trio); minio-init exits 0
docker stats --no-stream                            # RAM within the mem_limits (~4 GB total)
curl -s http://localhost/health                     # via Caddy on :80 (from the box) — expect 200
curl -s http://<EC2_IP>/health                      # via Caddy on :80 (public) — same 200
# gateway is NOT host-published; to hit it directly for debugging:
docker compose -f docker-compose.prod.yml exec gateway sh -c 'wget -qO- localhost:4000/health' 2>/dev/null || true
```
The gateway is **not** host-published; the public entrypoint is Caddy on port 80 → `gateway:4000` (it also
proxies the realtime websocket). Media via MinIO needs a domain — see phase 2.

## 7. Phase 2 — domain + HTTPS (when you have a domain)
Caddy is already in compose with **443 published** and a persistent `caddy_data` volume — so this is a
small switch, no new container:
1. 🟦 DNS A-records: `api.example.com`, `media.example.com` → EC2 IP.
2. 🖥️ edit `infra/caddy/Caddyfile` with your real hostnames.
3. 🖥️ point the caddy service at the HTTPS Caddyfile — in `docker-compose.prod.yml`, change the caddy
   mount from `./infra/caddy/Caddyfile.http` to `./infra/caddy/Caddyfile`.
4. 🖥️ in `.env`: `PHX_HOST=api.example.com`, `WEB_ORIGIN=https://app.example.com`,
   `CORS_ORIGIN=https://app.example.com`, `MINIO_PUBLIC_ENDPOINT=https://media.example.com`.
5. 🖥️ `docker compose -f docker-compose.prod.yml up -d` — recreates the app containers with the new env
   and Caddy with the domain config. Auto-HTTPS provisions Let's Encrypt certs (needs 80+443 open + DNS
   resolving). Verify `https://api.example.com/health`.

## 8. Web frontend (Next.js `web` service) — web.growblic.com + admin.growblic.com
One container serves both: chat at `/`, admin at `/admin`; Caddy routes both domains to `web:3000`
(internal-only, not host-published). `NEXT_PUBLIC_*` values are baked into the JS bundle **at build
time** (compose build args) — rebuild `web` after changing them.

1. 🟦 DNS A-records: `web.growblic.com`, `admin.growblic.com` → EC2 IP.
2. 🖥️ on the server:
```bash
cd chat-platform && git pull
# .env: NEXT_PUBLIC_API_BASE_URL / NEXT_PUBLIC_REALTIME_URL (defaults already point at
# https://api.growblic.com / wss://api.growblic.com/socket), and make sure WEB_ORIGIN + CORS_ORIGIN
# include https://web.growblic.com,https://admin.growblic.com (comma-separated — both parsed as lists).
docker compose -f docker-compose.prod.yml build web        # Next.js build; ~fine on 2 vCPU with swap
docker compose -f docker-compose.prod.yml up -d web        # start the container
docker compose -f docker-compose.prod.yml restart caddy    # pick up the web/admin Caddyfile blocks
docker compose -f docker-compose.prod.yml up -d            # recreate backend if WEB/CORS_ORIGIN changed
```
3. 🖥️ verify: `https://web.growblic.com` (chat) and `https://admin.growblic.com/admin` (admin) — Caddy
   auto-provisions certs for the new hostnames on first request/startup.

---

## Notes / decisions
- **Kafka:** `KAFKA_BROKERS` **is** honored at runtime (runtime.exs), so fanout works if Kafka runs — the
  earlier "baked-broker" worry was wrong. It's purely a keep-vs-defer-for-RAM choice. Deferring it only
  removes push-notification fanout; login, chat, realtime, media, admin all work.
- **Ports:** only Caddy (80/443) is host-published. Gateway 4000 is NOT published (Caddy reaches it at
  `gateway:4000` over chatnet); Redis is internal-only; MinIO is loopback-bound (Caddy fronts it); the
  domain services use `expose` (chatnet only).
- **Data:** named volumes `pgdata`/`kafka_data`/`minio_data`/`redis_data`/`caddy_data`/`caddy_config`
  persist across restarts (caddy_data holds the TLS certs). Back up Postgres regularly
  (`docker compose exec postgres pg_dump …`). `docker builder prune` to reclaim disk.
- **Web frontend** is the `web` compose service (Next.js standalone, `apps/web/Dockerfile`, mem_limit
  512m, internal-only :3000). Caddy serves it at web.growblic.com + admin.growblic.com — see §8.
