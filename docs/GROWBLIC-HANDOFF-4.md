# Growblic — Project Handoff

**Purpose of this file:** everything a fresh session needs to continue work on Growblic without asking. Read it top to bottom once, then use it as reference.

**Last updated:** 23 September 2026 (afternoon IST). Supersedes the 23 Sep morning / 13 Sep versions and HANDOFF-3 (12 Sep). Companion: `GROWBLIC-METHOD.md` (how we work — process, not state). Both live in `chat-platform/docs/`.

**What changed since the 13 Sep version (read this first):**
- A native **iOS app** exists (`Jaspreet2121/growblic-ios`, on the Mac mini) — Slices 0–14b done, Slice 15 in batches. See §8b.
- Backend **`8412f4a` is live on all 7 app services** (deployed 23 Sep 03:45 IST): APNs sender (disabled until the key exists), account deletion, 30 s refresh grace window, reviewer allowlist, AASA, dating-photo guard, reply-as-accept. Migrations **129 + 130** applied.
- Web **`3412eee`** live: refresh-on-401 (single-flight) + message-requests bucket.
- Marketing site **`cddc863`** live: `/delete-account` page for Play; privacy policy §6 fixed.
- Android: `client_msg_id` was **never sent by any release** until `185966a`; paging, presence, OTP, key-publish fixes; account deletion `4dfbdfd`.
- **Caddy is in a fragile state until the maintenance window** — do NOT restart Caddy or reboot EC2 (§5 #4, §10).
- The owner now **runs every EC2 command himself** (EC2 Instance Connect in the browser). Claude Code has no SSH to the box. The planner writes the exact block.

---

## 1. What Growblic is

A CPaaS / messaging platform for the Indian market — chat, voice/video calls, meetings, status, nearby discovery, and a dating ("Matches") surface, plus an SDK/API layer for third parties (the "v1 integrator" API, which creates its own end-user accounts). Built and run by one founder (Jaspreet), with AI agents doing the implementation.

Formerly called Skifi / ExWay. Some identifiers are frozen at those old names and **must not be renamed** (see §4).

**Owner's original six-feature list is complete**: voice-to-text, translation, animated emoji, shared chat wallpaper, disable sharing, animated profile pictures.

Clients: **Android** (Kotlin/Compose), **web** (Next.js), **iOS** (SwiftUI, in progress — feature parity with Android is the goal).

---

## 2. The machines, repos, and who does what

| Machine | Repo / path | Owns |
|---|---|---|
| **Mac Air** | `~/projects/chat-platform` (`Jaspreet2121/chat-platform`) | Elixir backend (umbrella) + Next.js web client (`apps/web`). **Android/iOS source is NOT here.** |
| **Mac Air** | `~/growblic-site` → **not prod** (see below) | Old marketing-site monorepo checkout; its `origin` is someone else's account. Work on the marketing site happens in a fresh clone of `Jaspreet2121/growblicwebsite`. |
| **Mac mini** | `~/AndroidStudioProjects/Growblic` | Android app (Kotlin/Compose). Package `com.growblic.exway`. |
| **Mac mini** | `~/developer/Projects/growblicchat` (`Jaspreet2121/growblic-ios`) | iOS app (SwiftUI). Bundle `com.growblic.exway`. |
| **Mac mini** | `~/chat-platform` | **Read-only backend reference** for the iOS/Android sessions. Always read `origin/main` via `git fetch` + `git show`, never its working tree. |
| **EC2** | `ubuntu@13.127.78.122`, `~/chat-platform` | Production. **Pulls only, never pushes.** Compose file: `docker-compose.prod.yml` — every command runs from `~/chat-platform`. |
| **EC2** | `~/growblic-site` (`Jaspreet2121/growblicwebsite`, main) | Marketing site `www.growblic.com`, deployed with `docker-compose.selfhost.yml` (§6). |

**Canonical marketing-site repo is `Jaspreet2121/growblicwebsite`.** `Jaspreet2121/growblic-website01` (monorepo with `apps/admin`) and `amanieheejhd-ship-it/growblic-website01` are NOT prod. Don't archive `growblic-website01` until it's confirmed nothing deploys from it.

**Working method — this is the whole operating model:**

- This chat (the "planner") **writes prompts**. It never runs commands itself.
- The owner pastes prompts into **Claude Code** on the Air or the mini (the mini has separate terminal tabs for iOS and Android).
- Claude Code does the work, reports back; the owner pastes the report here (often as screenshots).
- **EC2 commands are written here and the owner runs them himself** in EC2 Instance Connect (browser). Claude Code has no SSH to the box and doesn't need it. Output comes back here; the planner checks each checkpoint before the next step.
- The planner reads reports, ratifies or corrects judgement calls, and writes the next prompt.
- Machines run **in parallel**; the planner keeps one queue per machine/tab.

**Communication:** the owner writes in Hinglish. Replies in Hinglish — concise, decisive, numbered where it helps. **One recommendation**, not a menu, unless the decision is genuinely the owner's (product/IA choices are). The owner will say "prompt do" / "command do" — give the paste-ready block. When the owner is confused about where to paste what, give a per-machine table + one combined prompt per machine.

**Prod smoke harnesses exist** at `scripts/smoke/` (sharing_smoke, user_updated_probe, socket_latency) using the allowlist accounts. A contract check is one command; don't rewrite them.

---

## 3. Standing rules for every slice

Non-negotiable; they appear in almost every prompt.

### Android (Mac mini)
- **Release builds only**: `assembleRelease` → re-sign with the debug cert → `aapt dump badging` shows no `application-debuggable` → `adb install -r`. (The vivo currently runs exactly this: release 1.9.0 vc43, re-signed with `~/.android/debug.keystore`.)
- **NEVER** `adb uninstall`, `pm uninstall`, or `pm clear`. (`am force-stop` and `pm grant` are fine.) A wipe regenerates `device_id` → a new FCM token row → a new identity for the server.
- R8/minification has caused production bugs. Debug-build verification proves nothing for serialization/reflection.
- Install cycles on HyperOS (POCO) can reset autostart; `install -r` does not change the FCM token.
- Universal APK is ~146–153 MB (ML Kit translate natives).
- **Test devices on an iPhone hotspot are METERED** (`ANDROID_METERED` DHCP hint) — every Wi-Fi-only download parks silently. Mark the hotspot "treat as unmetered", or use "Download on this network anyway".

### iOS (Mac mini) — owner's current rules (23 Sep)
- **Simulator only for now.** No installs or checks on the real iPhone until the owner says so; every device check goes into PARITY under **"Real-iPhone batch (later)"** and is done in one pass.
- **Basic testing** (owner, 22 Sep: "don't do this much testing"): build + existing tests green, one smoke per feature, **max 3 new unit tests per batch**, no mutation tables. If a UI assertion fails for a reason other than the feature, report it — don't chase it.
- **Two simulators, two jobs:** `iPhone 17` runs the test suite (signed out; UI tests use `-growblic-reset-state`). `iPhone 17 Pro` holds the signed-in smoke session — **never reset, uninstall or run the suite there** (doing so signed the test account out twice).
- Signed-in smoke tests are opt-in: `TEST_RUNNER_GROWBLIC_SMOKE=1 xcodebuild test …` (xcodebuild only forwards `TEST_RUNNER_`-prefixed vars).
- Every background shell gets a deadline counted inside the loop (**macOS has no `timeout` command**), and all background shells are killed before a report.
- `project.pbxproj` edits need Xcode quit first. Don't commit Xcode noise (pbxproj reshuffles, Info.plist comment removal); do commit `Localizable.xcstrings` with Xcode's empty entries.
- Backend truth = `~/chat-platform` **at origin/main**. When Android contradicts the backend, iOS follows the backend and records the deviation; Android bugs are not ported.

### Both / all repos
- **Exact-path staging** — never `git add .` / `-A` or by directory.
- **Named commits, straight to `main`, pushed at the end. Push ≠ deploy.** No feature branches.
- **Mutation-proven tests** for backend/Android: apply the mutation, paste the RED output, revert byte-identical, confirm GREEN. **Confirm the mutation actually applied** — anchors have matched a different function and the suite ran unmutated.
- **Two-phase for anything non-trivial**: INSPECT, report, STOP; BUILD after the owner reads it.
- **Measure, don't guess** — for perf, design, and feasibility.
- **Every outcome names itself.** No `:ok` / `[]` / `nil` return on a hot path without an info log naming the outcome.
- **Fixtures are built from the producer, or from a real wire body** — never hand-typed to match the consumer.
- **Destructive migrations**: dry-run script that ends in ROLLBACK, full `pg_dump` first, STOP for owner confirmation, then apply.
- **Test credentials never go into docs** — except the App Review demo login in `APPSTORE.md` (owner's explicit request). Never paste secret values into this chat; mask them in terminal output (`sed -E 's/(\+15550100001:)[0-9]+/\1******/'`).

### Design work
- Audit slices produce measured dp tables and screenshots and change nothing. The fix slice comes after.
- If a number lands outside the ask, **say so rather than silently adjusting**.

---

## 4. Frozen identifiers — do not rename

- Wire prefix `skifi-link:v1:`
- HKDF info string `skifi-offline-v1:box`
- Android package `com.growblic.exway`; **iOS bundle id `com.growblic.exway`** (registered to team `FXGBWKT8FB` — never to a Personal Team)
- iOS NSE bundle `com.growblic.exway.NotificationService`; App Group `group.com.growblic.exway`; VoIP topic `com.growblic.exway.voip`
- Apple Team ID **`FXGBWKT8FB`** (GROWBLIC PRIVATE LIMITED) — in the AASA appID `FXGBWKT8FB.com.growblic.exway`
- Signing cert SHA `A3:CE:...` (debug cert re-sign SHA-256 `1bfb4aa0…898473`)
- IndexedDB name `skifi-e2ee`
- localStorage keys `chat_device_id`, `chat_platform_access_token`, `chat_platform_refresh_token`, `chat_platform_session_id`, `skifi-e2ee-device-seen`, `theme`
- iOS `device_id` format `ios-<uuid>`, session platform `"ios"` (lowercase; the only accepted spelling)

---

## 5. Architecture invariants — break these and things fail silently

1. **`MESSAGE_STORE_ADAPTER=scylla` in prod. The Postgres `messages` table is EMPTY.** Any `SELECT … FROM messages` in prod returns nothing. Four bugs so far. **Always check which store a query hits.** Consequence for backups: the nightly/predeploy `pg_dump` contains **zero messages**; there is no Scylla backup yet (§10).
2. **Config like `:tokens` goes in `runtime.exs`, not `config.exs`.**
3. **`--force-recreate` when redeploying** a running service, and **`--no-deps`** when a single service is recreated after an `.env`/compose change (otherwise compose can recreate postgres/kafka/etc. whose config "changed").
4. **Caddy — CURRENT STATE IS FRAGILE (23 Sep):**
   - Prod Caddy still runs the old container with **single-file bind mounts**: `infra/caddy/Caddyfile → /etc/caddy/Caddyfile` and `infra/caddy/assetlinks.json → /srv/.well-known/assetlinks.json`. `git pull` replaces files by rename, so the container keeps the old inode — `caddy validate` + `reload` from `/etc/caddy/Caddyfile` silently reload STALE config.
   - The running config was loaded on 23 Sep via a workaround: the new Caddyfile copied to `/tmp/Caddyfile.new` inside the container, validated and reloaded from there (md5 `bd1acc7b…` = the Caddyfile at `8412f4a`).
   - `59647d2` moved `assetlinks.json` to `infra/caddy/srv/.well-known/` and switched compose to **directory mounts** (`./infra/caddy:/etc/caddy:ro`, `./infra/caddy/srv:/srv:ro`). The host no longer has `infra/caddy/assetlinks.json`, so **if the old Caddy container restarts before the maintenance window, assetlinks breaks or Caddy fails to start.**
   - **Do not restart Caddy, do not reboot EC2, never run a bare `up -d`** until `docs/deploy/maintenance-window.md` steps 1–2 are done. After that, the rule is: validate from disk via `docker run`, md5 the file inside the container against the working tree, then reload.
   - Caddy path matchers are **case-insensitive** — use `path_regexp` for case-sensitive rules.
   - The **AASA is served inline** (`handle /.well-known/apple-app-site-association` + `respond` one-line JSON, `Content-Type application/json`, 118 bytes) inside the existing `web.growblic.com` block — never a second `web.growblic.com { }` block (ambiguous site def → restart loop). Check the body with curl, not just the status.
5. **Deploy order: gateway with-or-before auth / conversation** (InternalApi `String.to_existing_atom`). An env-only change (no image change) may recreate `auth` alone.
6. **Media deploy order:** gateway/message/user first, media LAST.
7. **Migration ALWAYS before the service that reads the new column.** Own block, verify, then services.
8. **Kafka offsets:** `offset_out_of_range` → earliest. Liveness/stall repair → committed. Never collapse these.
9. **One brod client per consumer group.**
10. **RealtimeFanOut:** `message_created` fans to both user and conversation topics; mutations (receipts/edits/deletes/reactions/polls) to the conversation topic only. Clients dedup by id. The sender's own socket create is NOT echoed back to the sender (`broadcast_from`).
11. **Only open chats join the conversation topic.** Anything that must reach a closed chat needs the user topic or a system message.
12. **`call:adhoc_invite`:** security checks BEFORE ring, fan-out LAST, uniform error.
13. **Push tokens (`fcm_tokens`):** one row per `(user_id, device_id, COALESCE(kind,''))` since **migration 129** — an iPhone registers two tokens (`kind: alert` + `kind: voip`); Android rows have `kind` NULL. `device_id` comes from the **session**, never the request body. New columns `kind`, `environment` (`sandbox` only for Xcode debug builds; **TestFlight and App Store are `production`**). The old `fcm_tokens_user_device_key` constraint did not exist on prod (129 printed a harmless NOTICE).
14. **FCM 404/410 = dead token → prune the row.** Keyed on the HTTP status. A 5xx never prunes.
15. **Every real user has a `user_profiles` row** from OTP verify onward.
16. **`users_auth` holds ~1642 active rows with `external_id`** — v1 integrator end-users, not shadow accounts. Metrics must filter `external_id IS NULL`.
17. **Timeline bucket walk is floored at `max(conversation.created_at − 1 day, today − 730d)`.**
18. **`user_updated`** (avatar change, to `peers_of/1`) and **`profile_changed`** (self-only; e.g. the UPI QR is generated async after `PATCH /users/me` — refetch on this frame) both exist on purpose.
19. **Postgres `now()` inside the Ecto sandbox is the transaction-start clock.**
20. **Media messages carry `metadata.media.download_url` (15 min) and `thumb_url`** on ack/event/inbox/timeline, attached after the Kafka publish. Sealed and view-once carry none. Presign TTL ceiling 900 s.
21. **Server image variants** (thumb 256/q70, medium 1280/q80) via vix/libvips for plain `image/*` ≤ 25 MB.
22. **`status_updated`** goes to `Statuses.audience_of/1`, never to the actor; `"expired"` is never emitted.
23. **Refresh requires `device_id` matching the session.** The gateway's `require_fields` only checks `refresh_token`, so a missing `device_id` surfaces as **401 `auth.refresh_invalid`** two services away. Tell apart: `refresh_invalid` = device mismatch/missing; `refresh_reused` = genuine reuse outside the grace window; **400** = gateway not rebuilt alongside auth.
24. **Refresh grace window (live 23 Sep):** re-presenting a just-rotated refresh token within **30 s** returns a valid pair for the same session (lost-response case) instead of `refresh_reused`; advisory-lock race-safe; outside the window reuse detection is unchanged. `AUTH_REFRESH_GRACE_SECONDS` controls it. Verified on prod: rotate 200 / inside 200 / outside 401 `refresh_reused`.
25. **Access TTL:** login still issues a long access token (3 h / 7 d with remember_me); rotation issues 900 s. Cutting login to 15 min ("Part 4") was held because web never refreshed — **web refresh-on-401 is now live (`f1cf618`), so Part 4 is unblocked** (owner decision, own slice).
26. **Message requests — reply = accept (`7324888`):** when the recipient (whose row has `request_pending_at`) sends into the conversation, `authorize_send` calls `MessageRequests.accept/1` — the same function as `POST /request/accept`. The original sender's messages never clear it (the 3-message budget stays). `/v1` does not implicitly accept.
27. **Account deletion (`POST /api/v1/users/me/delete`, live 23 Sep):** re-auth with the account's own phone number in the body; revokes sessions, deletes device keys/profile/media/Matches/Nearby; tombstone sets `phone_number = NULL` (partial unique index → the number can re-register at once); **username held 30 days** (`username_holds`); `conversation_participants` get `left_at` (not deleted) so peers see "Deleted account"; messages stay in peers' history. Errors: 403 `account.reauth_failed`, 403 `account.undeletable`, 404 `account.not_found`.
28. **Reviewer allowlist `REVIEWER_TEST_LOGINS`** is ONE comma-separated line in `.env`, no spaces, `+number:6digits`. Malformed entries are dropped silently — always check the boot log line `reviewer test logins: N configured` (**expect 6**). Allowlisted OTP requests are byte-identical to normal ones.
29. **History paging:** Scylla ignores `before_created_at/before_id` and needs the opaque `next_cursor` (`"<date>|<timeuuid>"`, passed back as `before=`). There is **no date cursor on Scylla**, so jump-to-date is Postgres-only on both clients until the backend adds one.
30. **Group E2EE is refused server-side** (422 `secret.not_supported` for groups) — groups are plaintext on every client.

---

## 6. Deploy recipes (EC2)

**Before any build — disk.** The root disk is 38 GB; on 23 Sep it was 81 % full (build cache 13 GB). Postgres and Scylla live on the same disk. `docker builder prune -f` freed it to 48 %. Check `df -h /` before a multi-service build.

Always:
```bash
cd ~/chat-platform && git pull origin main && git log --oneline -1     # confirm the SHA
export GIT_SHA=$(git rev-parse --short HEAD) && echo $GIT_SHA          # REQUIRED before any build
```
Forgetting `GIT_SHA` doesn't fail the build — the service just reports `"unknown"`. For long builds without tmux, save it: `echo "$GIT_SHA" > ~/.deploy_expected` and re-export after a reconnect.

### Backend service (gateway / conversation / message / user / media / auth)
```bash
docker compose -f docker-compose.prod.yml build <service>
docker compose -f docker-compose.prod.yml up -d --no-deps --force-recreate <service>
sleep 25
docker compose -f docker-compose.prod.yml ps <service>
docker compose -f docker-compose.prod.yml logs --since 3m <service> 2>&1 | grep -iE 'error|crash|terminating' | tail -5
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://api.growblic.com/api/v1/auth/refresh \
  -H 'content-type: application/json' -d '{"refresh_token":"junk","device_id":"junk"}'   # expect 401
curl -s https://api.growblic.com/health; echo      # {"status":"ok","service":"api_gateway","git_sha":"<sha>"}
```

**Multi-service deploy (what 23 Sep used).** `shared_infra` is statically embedded in every release, so a `shared_infra` change means **all seven** app images rebuild. Build in the background so a dropped browser session can't kill it, then bring everything up in ONE command (auth + gateway together):
```bash
nohup sh -c 'for s in gateway auth conversation user message media notification; do echo "=== $s ==="; docker compose -f docker-compose.prod.yml --profile kafka --profile scylla build "$s" || { echo "BUILD FAILED: $s"; exit 1; }; done; echo ALL-BUILT' > ~/build-$(date +%F).log 2>&1 &
grep -E "^===|ALL-BUILT|BUILD FAILED" ~/build-$(date +%F).log      # poll
docker compose -f docker-compose.prod.yml --profile kafka --profile scylla up -d --no-deps gateway auth conversation user message media notification
for s in gateway auth conversation user message media notification; do got=$(docker compose -f docker-compose.prod.yml --profile kafka exec -T "$s" sh -c 'echo $GIT_SHA' | tr -d '\r'); printf '%-14s %s\n' "$s" "$got"; done
```
Every line must print the expected SHA — a forgotten service looks healthy and only shows up as a 400 on refresh.

### `.env`-only change (e.g. the reviewer allowlist)
```bash
cp .env ~/.env.bak-$(date +%F-%H%M)
# edit with a targeted sed, run it ONCE, print masked
docker compose -f docker-compose.prod.yml --profile calls --profile kafka up -d --no-deps --force-recreate auth
sleep 25
docker compose -f docker-compose.prod.yml logs --since 1m auth 2>&1 | grep -i 'reviewer test logins'   # expect 6 configured
```
`up -d`, not `restart` — `restart` keeps the old environment. Then do a real login per affected number (OTP request + verify with a `device_id`), printing only OK/error code.

### notification (Kafka consumer, no HTTP health)
```bash
export COMPOSE_PROFILES=kafka          # REQUIRED — it sits behind profiles: ["kafka"]
docker compose -f docker-compose.prod.yml build notification
docker compose -f docker-compose.prod.yml up -d --no-deps --force-recreate notification
docker compose -f docker-compose.prod.yml exec -T notification sh -c 'echo $GIT_SHA'
for g in notification-service-message-created notification-service-call-incoming notification-service-conversation-participants; do
  docker compose -f docker-compose.prod.yml exec -T kafka /opt/bitnami/kafka/bin/kafka-consumer-groups.sh \
    --bootstrap-server localhost:9092 --group $g --describe 2>/dev/null | awk -v g=$g 'NR>1{s+=$6; n++} END{print g": lag="s+0" partitions="n+0}'
done
```

### Migration (ALWAYS its own block, verified, before any service)
```bash
docker compose -f docker-compose.prod.yml exec -T postgres pg_dump -U chat_user chat_platform | gzip > ~/predeploy-$(date +%F).sql.gz
ls -lh ~/predeploy-$(date +%F).sql.gz && gunzip -c ~/predeploy-$(date +%F).sql.gz | head -5   # MBs, "PostgreSQL database dump"
diff apps/backend/apps/shared_infra/priv/schema/<NNN>_*.sql infra/docker/postgres/init/<NNN>_*.sql && echo SAME
docker compose -f docker-compose.prod.yml exec -T postgres psql -U chat_user -d chat_platform -v ON_ERROR_STOP=1 \
  < apps/backend/apps/shared_infra/priv/schema/<file>.sql
# then verify the new columns via information_schema or \d. Column not visible → STOP.
```

### Web (container behind Caddy at `web:3000`)
```bash
docker compose -f docker-compose.prod.yml build web
docker compose -f docker-compose.prod.yml up -d --no-deps --force-recreate web
curl -s -o /dev/null -w "%{http_code}\n" https://web.growblic.com      # 307
```
Env is baked at build time. Check in an **incognito** window (the PWA service worker caches the old bundle).

### Marketing site (`www.growblic.com`, repo `Jaspreet2121/growblicwebsite`)
Prod runs from `~/growblic-site/docker-compose.selfhost.yml` — service `growblic-site`, container `growblic-site`, volume `growblic-site_leads` (contact-form leads), external network `chat-platform-prod_chatnet`, no host port; Caddy proxies `growblic-site:3000`. **`compose.yaml` in the repo is local-only** (it publishes 3000:3000 and uses a different volume). The file is untracked on the box (commit pending).
```bash
cd ~/growblic-site
git pull --ff-only origin main && git log --oneline -1
docker compose -p growblic-site -f docker-compose.selfhost.yml build growblic-site
docker rename growblic-site growblic-site-old && docker stop growblic-site-old
docker compose -p growblic-site -f docker-compose.selfhost.yml up -d growblic-site
sleep 15
docker inspect growblic-site --format '{{range .Mounts}}{{.Name}} -> {{.Destination}}{{end}}'   # growblic-site_leads -> /app/data
for p in "" delete-account privacy terms; do curl -s -o /dev/null -w "$p %{http_code}\n" https://www.growblic.com/$p; done
docker rm growblic-site-old          # only after all 200
# rollback: docker rm -f growblic-site && docker rename growblic-site-old growblic-site && docker start growblic-site
```
`RESEND_API_KEY` is **empty** in prod → the contact form saves leads to the volume but sends no email. An older unused volume `growblic-site_growblic-leads` exists — don't delete it before checking it for old leads.

### Caddy
**Until the maintenance window is done, see §5 #4 — don't touch it.** After the window: validate from disk (`docker run --rm -v …/infra/caddy:/etc/caddy:ro caddy:2.8-alpine caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile`), md5 the file inside the running container against the working tree, then `caddy reload`. Recreate only as a planned step.

### Post-deploy consumer check (after ANY `message` recreate)
```bash
docker compose -f docker-compose.prod.yml exec -T kafka /opt/bitnami/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 --group message-service-inbox-projection --describe | awk 'NR>1{s+=$6} END{print "inbox lag:", s}'
docker compose -f docker-compose.prod.yml exec -T message bin/message_service rpc '
  alias MessageService.Events.ConsumerClients
  for {g, c} <- ConsumerClients.all() do
    n = Enum.count(0..5, fn p -> match?({:ok, _}, :brod.get_consumer(c, "message.events.v1", p)) end)
    IO.puts("#{g}: #{n}/6")
  end'
```
Expect `inbox-projection 6/6`, `search-index 6/6`, `conversation-summary 0/6`, `log-consumer 0/6`.

### Live auth checks after an auth deploy (demo account only)
Use `+15550199001 / 900001`. **Every refresh call must send `device_id`** matching the login. Rotate → 200; replay the old token within 30 s → 200 with a new pair; after 35 s → 401 `auth.refresh_reused`. Delete the temp files holding tokens afterwards.

### "Is the new code actually running?"
- Public: `curl https://api.growblic.com/health` → `git_sha`.
- Inside a container: `docker compose … exec -T <svc> sh -c 'echo $GIT_SHA'`.
- **Do NOT `grep` a BEAM file for a string literal.**
- For a container you didn't create: `docker inspect <name> --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}'` — empty means it was started by hand; inspect mounts/env before redeploying.

---

## 7. Production state (23 Sep, afternoon)

**Backend/web repo `chat-platform`** — remote main ≥ `3412eee` (later commits are docs only).

| Service | Running SHA | Notes |
|---|---|---|
| gateway (+realtime) | `8412f4a` | reply-as-accept frames, push route kind/environment, user delete route |
| auth | `8412f4a` | refresh grace window, account deletion, APNs token store, reviewer allowlist (6) |
| conversation | `8412f4a` | reply-as-accept (`authorize_send`) |
| message | `8412f4a` | |
| user | `8412f4a` | dating-photo purpose guard (user_avatar only) |
| media | `8412f4a` | |
| notification | `8412f4a` | APNs sender built, **disabled** (APNS_* env unset) |
| web | `3412eee` | refresh-on-401 single-flight, message-requests bucket |
| caddy | old container (~19 Sep) | config reloaded 23 Sep from `/tmp/Caddyfile.new` (Caddyfile @ `8412f4a`, AASA live) — **fragile, see §5 #4** |
| marketing site | `cddc863` (growblicwebsite) | `/delete-account`, privacy §6, footer + sitemap |

All seven app containers verified to report `8412f4a`; `/health` 200; AASA `200 application/json 118`.

**Android repo** — remote main ≥ `4dfbdfd`: cross-platform fixes `185966a..40fe6be`, presence skew `ac21992`, account deletion `4dfbdfd`. Release build **1.9.0 / versionCode 43**, on the vivo (debug-keystore re-sign). **Play AAB is stale** (built before these fixes) — rebuild before upload.

**iOS repo** `growblic-ios` — main at Slice 15 Batch 1 (`36a7ab1` + follow-ups). No TestFlight yet.

### Migrations applied
116 calls adhoc · 117 wallpaper · 118 e2ee two-party OFF · 119 auto-reply unwrap · 120 `conversation_settings.sharing_disabled` · 121 `fcm_tokens` NOT NULL device_id · 122 `user_profiles` display_name nullable · 123 shadow-account delete (deleted 0) · 124 `media_assets.variants` · 125 `dm_streaks` + participant columns · 126 `checklist_items` · 127 `view_once_expiry` ledger · 128 `conversation_participants.request_pending_at` · **129** `fcm_tokens.kind`/`environment` + unique per kind (APNs) · **130** account deletion (`users_auth.deleted_at`, username holds). Backups: `~/predeploy-2026-09-23.sql.gz` (1.6 MB, PG only), `~/backups/` nightly.

### Frozen config
`REVIEWER_TEST_LOGINS` — 6 entries (codes for the first two live only in `.env` / the owner's password manager; never write them here):

| Number | Code | Use |
|---|---|---|
| `+15550100001` | secret (`.env`) | Google Play reviewer |
| `+15550100003` | secret (rotated 23 Sep from the weak `111111`) | "Nearby Tester" test account |
| `+15550199001` | `900001` | harness A (backend smoke, `scripts/smoke`) — internal, never give to reviewers |
| `+15550199002` | `900002` | harness B |
| `+15550199003` | `900003` | **Apple App Review** demo login (reviewers may delete it) |
| `+15550199004` | `900004` | account-deletion testing — re-registers after deletion; use a new username each run (30-day hold) |

- Nightly PG backup: cron `30 21 * * *` → `~/bin/pg-backup.sh`, 14-day retention, `~/backups/`. **No Scylla backup exists.**
- MinIO: anonymous=private, 9000 bound to 127.0.0.1 only, 9001 never published
- Kafka consumer flags: `KAFKA_INBOX_CONSUMER_ENABLED=true`, `KAFKA_SEARCH_CONSUMER_ENABLED=true`; the other two off deliberately.
- FCM: `android.priority: "high"`, data-only envelope.
- `.env` backups from 23 Sep: `~/.env.bak-2026-09-23-*`.
- EC2 says **"System restart required"** (kernel updates) — reboot is the last step of the maintenance window.

### Apple Developer account
- Org team **GROWBLIC PRIVATE LIMITED**, Team ID `FXGBWKT8FB`. Account Holder: Suman Rani. `growblic@gmail.com` is **Admin** (can create APNs keys, register devices) and is signed into Xcode on the mini.
- Membership had **expired**. The 21 Sep ₹8,700 charge was an **"Add Funds to Apple Account"** top-up (balance can't pay for membership). The real membership was bought 22 Sep via the Apple Developer app (auto-renews 22 Sep 2027); **activation pending (~48 h)** — Xcode shows a red ✖ on "Certificates, Identifiers & Profiles" for the team until then.
- Until then the real iPhone runs a **Personal Team** build: bundle `com.growblic.exway.dev`, team `9LTA7334YY`, local-only files under `LocalDevice/` + an untracked `growblicchat-device.xcodeproj` (both gitignored); no push/NSE/App Group; the profile **expires ~30 Sep**.
- When active: create the APNs key (Keys → + → APNs, Sandbox + Production, team-scoped) → `scp` the `.p8` to `~/secrets/` on EC2 (`chmod 600`, never in git or chat) → set `APNS_KEY_ID`, `APNS_TEAM_ID=FXGBWKT8FB`, key path → `up -d --no-deps --force-recreate auth notification` → a dummy token must return `BadDeviceToken`.

### Data facts
- `users_auth` active: ~52 real (phone) + ~1642 v1 external end-users.
- Gateway REST p50 3–15 ms; socket send→receive ~51 ms = WAN. **The backend is not the bottleneck.**

### Test devices
| Device | Id | Account | Notes |
|---|---|---|---|
| POCO M6 Pro 5G (HyperOS) | `14318ff5e462` | @wanted / Bintu Malik (also used as @guru "Placeholder User" in iOS smokes) | **No app installed** (MIUI `adb uninstall` one-way door) — Developer options → Install via USB. Often not with the owner. |
| vivo V2303 | `10BDAG14L3000MF` | **@growblic01 ("Growblic")** | Release 1.9.0 vc43, debug-keystore re-sign; device keys published. Used as the Android peer for iOS calls/E2EE. |
| OPPO CPH2495 | `W8SWPNLZAU45KNWG` | @Suman | Not attached for many sessions. |
| iPhone ("Bintu iPhone") | UDID `00008120-000221812693C01E` | iOS test account | Personal Team `.dev` build; real-iPhone batch deferred. |
| iPhone 17 Pro simulator | — | iOS test account (27 chats) | **Signed-in smoke session — never reset.** One chat `d25e19bf` intentionally locked. |
| iPhone 17 simulator | UDID `…7E68EC7DDC9D` | signed out | Test suite. |

Harness state: A–B DM has `e2ee_disabled` set; "Sharing Smoke" group `9ef3cc1a`; "gbtest paging 0923" group (99 numbered messages, p061–p081 missing due to rate limit) — **keep as a paging fixture**; iOS "Slice" test group.

---

## 8. What has been completed

### 22–23 Sep

**iOS app (new)** — see §8b.

**Backend "iOS unblock" slice** (deployed 23 Sep as `8412f4a`):
- **APNs sender** (migration 129): ES256 provider token, HTTP/2 pool, alert + VoIP (`apns-push-type voip`), token route `POST /api/v1/push/fcm-tokens` takes `platform:"ios"`, `kind: alert|voip`, `environment`. **Found:** the token row was `UNIQUE (user_id, device_id)` — an iPhone's VoIP registration would have overwritten its alert token (messages arrive, calls never ring). Now keyed per kind with `COALESCE(kind,'')` because NULLs are distinct in a unique btree. Payloads: message pushes `aps.alert`, `mutable-content: 1`, `thread-id` = conversation id, top-level `type, conversation_id, message_id, sender_id, sender_name, unread_count, group_name?`; sealed adds `"sealed": true` and no plaintext; calls are VoIP with empty `aps` and `type:"call", call_id, call_type, caller_id, caller_name, e2ee`; stop = `type:"call_cancelled"`. Contract: `docs/05-api-contracts/ios-push.md`. **Disabled until the key exists.**
- **Account deletion** (migration 130): catalog-driven purge reading `pg_constraint` (41 cascading columns, pinned by a test), tombstone, re-auth, participants get `left_at`.
- **Refresh grace window** (30 s, advisory lock) — the lost-response → `refresh_reused` → full local wipe on Android/iOS is gone.
- **Reviewer allowlist** for App Review + deletion testing (§7).
- **AASA** inline in Caddy; **dating-photo PATCH** rejects non-`user_avatar` assets (previously accepted and failed later on the presign clamp).
- **Reply-as-accept** (`7324888`) — a stranger's DM stuck pending forever on web (no Accept UI) now clears when the recipient replies.
- Docs: `SECURITY_MODEL.md` E2EE section rewritten from code; `docs/deploy/2026-09-23.md` runbook; `docs/deploy/maintenance-window.md`; `docs/09-devops/REVIEWER_LOGIN.md`.
- **Deploy lessons (23 Sep):** runbook step 7 omitted `device_id` → every refresh 401 `refresh_invalid` (looked like a broken grace window); Caddy reload served stale config (inode trap); the doc said "5 configured", prod had 6 (an undocumented `+15550100003`).

**Web** (`f1cf618`, `3412eee`, deployed 23 Sep): `request<T>()` in `api.ts` was the single chokepoint and cleared the session on ANY 401 — now a single-flight refresh (N concurrent 401s → one `/auth/refresh` with `device_id`; many parallel refreshes of one token look like reuse and would sign the user out), retry once, sign out only on `refresh_expired|refresh_invalid|session_revoked|refresh_reused`, never on a network error. Message-requests bucket is a separate fetch (the normal inbox excludes pending rows, so filtering in memory would be permanently empty).

**Marketing site** (`cddc863`): `/delete-account` written from `AuthService.AccountDeletion` (what's deleted, what's kept and why, in-app steps, contact); **privacy policy §6 still described email deletion within 30 days** — now leads with the in-app route. Footer + sitemap. Live 200.

**Android** (22–23 Sep, from the iOS port's contract audit):
- `client_msg_id`: **no release had ever sent one** — an Offline-messages toggle (ships OFF, no UI) gated it (`OfflineWirePolicy`, deleted). Socket timeouts could duplicate messages; the idempotency ledger is now exercised.
- Paging: `MessageCursor` carries both the keyset and Scylla's opaque `next_cursor`; old history actually loads on prod.
- Presence: `presence:subscribe` for the open peer, keyed on (peer, socket epoch); presence frames arrive on the user topic. Clock skew: a last-seen up to 60 s in the future reads "last seen just now" and the header re-renders on the minute (`ac21992`).
- `auth.otp_attempts_exhausted` mapped (was "Your session expired").
- Device-key publish: a failed registry fetch was treated as fine and the self-heal upload scheduled no retry — fixed; root cause of @guru having no keys NOT proven (needs the POCO).
- In-app **account deletion** (`4dfbdfd`), matching iOS; also removes the number from login recents.
- Jump-to-date: Postgres-only (no Scylla date cursor).
- Auth Slice B had already shipped on 4 Sep.

### Before 22 Sep
See the 13 Sep version of this file / HANDOFF-3 for full paragraphs. Headlines: QR link poll crash; `sharing_disabled` (120); `/health` git_sha; FCM prune + outcome logging + one row per device (121); `user_updated`; Postgres gate fixed (40 suites had never run); timeline floor; profile 404 + backfill (122); shadow-account inquiry (123 deleted 0); media server half (inline download_url, variants) + client half; `status_updated`; font + entities whitelist + spoiler masking + web rich text; Best Friends server half (125) + client; checklists (126) and the four server bugs the device found (3-tuple encode 503, blank inbox previews, unmapped errors, non-atomic stale check; polls hydrated only on the PG adapter); four correctness fixes (`4fffcb8`); radial hub; Telegram-style media bubbles; video viewer stretch; sealed media stuck pending; message requests phase 1 (128) + `REDIS_URL` missing in message-service; 16 KB alignment (`6f4fbb2`); auto-backup token leak; hardware features not required; view-once expiry ledger (127); SMS Retriever (shipped OFF — DLT template `1477178966975013590` pending approval); login screen redesign; backend hygiene (`df7cbb0`, CI green); custom fonts; rich text slices 1–3; on-device translation + transcription; decrypt-on-ingest (`343b87f`, §11); smart reply chips; custom notification sounds + call ringtones.

---

## 8b. iOS app (Mac mini, `Jaspreet2121/growblic-ios`)

**Stack (locked in `CLAUDE.md`):** SwiftUI, iOS 17.0 min, iPhone only, portrait, Swift 6 (default MainActor isolation, approachable concurrency). MVVM + Repository; **GRDB is the single source of truth** (UI observes via ValueObservation; network/socket only write to it). REST for auth/history/sync/media; Phoenix Channels for live events via **SwiftPhoenixClient 5.3.5** behind a `RealtimeClient` protocol. Chat list = UICollectionView + diffable + `UIHostingConfiguration` cells. Packages: GRDB 7.11, SwiftPhoenixClient, swift-sodium 0.11, LiveKit client-sdk-swift 2.17, lottie-spm 4.6.1. Keychain `AfterFirstUnlockThisDeviceOnly`; install-marker purge (Keychain survives uninstall). Fonts Barlow Condensed + Manrope + 5 OFL chat fonts. Docs in the repo: `CLAUDE.md`, `docs/CONTRACTS.md` (3k+ lines, every wire contract + Appendix B mismatches), `docs/PARITY.md` (feature tracker, "Real-iPhone batch (later)"), `docs/APPSTORE.md` (listing drafts, review notes, privacy answers).

**Done:** Slice 0 (inventory, config) · 1 auth (single-flight refresh, AuthFailurePolicy, same-user guard) · 2 shell + inbox + message requests · 3 realtime + chat + seamless send (`client_msg_id` always) · 4 E2EE (publish guard, sealed frames, delivered receipts) · 5 media + camera + attach grid + QR · 6 actions, view-once, details, groups, polls/checklists/location/albums, pins, in-chat FTS5 search, export, disappearing · 8 calls (CallKit + LiveKit, foreground ringing) · 9 Status · 10 Matches (43 turn-on tiles; slug from the label, not the key) · 11 Nearby online (significant-location-change window, no MultipeerConnectivity — Android-compatible offline transport needs a Nearby Connections spike) · 12 settings/extras · 13 broadcast, quick replies, auto-replies, UPI (server-generated QR) · 14a leftovers + privacy manifest + UGC report/block on groups and Matches cards + App Store screenshots · 7a push client side (NSE target, App Group migration incl. WAL/SHM, PushKit → CallKit) · 14b account deletion UI, push registration seam, search→message jump (global search had been silently empty since Slice 12) · Slice 15 Batch 1 (app-switcher cover, push fixes, restricted sharing live, sealed backlog batching, decrypted inbox preview; locked chats had been unreachable).

**Real-iPhone findings fixed 23 Sep:** `voip` background mode was missing → CallKit refused every request and the app ended calls 10–25 ms after connect (every build affected); People rows in search had no tap action; photo/video upload failures were a network TLS fault (5G), not the app.

**Queue:** Slice 15 Batches 2–5 (chat screen · details/groups/group calls — confirm server support first · settings + inbox · calls + translate/transcribe + background live location, WhenInUse only). Then **Slice 7b** once the team is active (real bundle id, entitlements, APNs/VoIP live, NSE sealed decrypt, associated domains `applinks:web.growblic.com`, TestFlight). Then the **real-iPhone batch** (camera, CallKit UI, Face ID, voice, translate/transcribe accuracy, E2EE Android↔iOS with @growblic01, live receive, deletion on `+15550199004`).

---

## 9. Bug classes learned — check for these

1. **The fixture mirrors the bug.** Build fixtures from the producer or a real wire body.
2. **A test that doesn't round-trip proves nothing.**
3. **Silent skip / silent stall / silent success.** Every outcome names its reason at info.
4. **The PG `messages` table is empty.**
5. **Debug vs release.** R8 has bitten twice.
6. **A mutation that goes green proves nothing** — confirm it applied.
7. **Inspect before fixing.**
8. **Browser engines differ.**
9. **`false || nil` is `nil`.** Use `Map.fetch` for boolean settings.
10. **Catch-all clauses absorb missing explicit clauses.**
11. **Postgres `now()` in the sandbox is transaction-start.**
12. **Casting in Postgres raises `Postgrex.Error`, not `Ecto.Query.CastError`.**
13. **Identity-keyed cache + invariant URL = always stale.** Key on content version.
14. **A crash that answers a soft state is worse than one that answers 5xx.**
15. **The screen must observe the store, not the last fetch.**
16. **Check premises about data in the DB before building on them.**
17. **The gate script must run every suite and print a table.**
18. **A guard that returns a failure without writing the failure state is a silent pend.**
19. **`mergeIncomingRow` must carry every locally-derived column** — merge-carry test in the same commit.
20. **A signature proves authorship, not safety.** Clients re-validate sealed fields at render time.
21. **When two clauses can match the same shape, order is load-bearing** — pin it with a test.
22. **Read the gate's table, never the tail of a grep.**
23. **Hiding a row from one list is not hiding it** — enumerate every reader.
24. **A service's config is part of the feature** — pin compose config with a test.
25. **A policy inside a shared helper is a policy the caller cannot log.** Helpers return facts.
26. **Single-file bind mounts serve stale config.** `git pull` renames a new file over the old; the container keeps the old inode, and `validate` + `reload` succeed on stale bytes. Mount directories; md5 inside the container; validate from disk.
27. **A missing field at the edge surfaces as a credential failure downstream.** Refresh without `device_id` = 401 `refresh_invalid`. When a runbook check fails, first diff the request against what real clients send.
28. **Compose after an `.env`/compose change can recreate dependencies.** Use `--no-deps` for single-service recreates; never a bare `up -d` while a planned recreate is pending.
29. **A container you didn't create may not match the compose file in the repo.** Check `config_files`, mounts, env keys and volumes before redeploying (the marketing site ran from an untracked file with a different service name and volume).
30. **Docs that state a count must be checked against the source.** "5 configured" vs 6 real would have read a correct allowlist as broken.
31. **A default gate can silently switch a wire field off for every release.** `client_msg_id` was gated by an OFF-by-default toggle with no UI — never sent. Grep release behaviour, not just the code path.
32. **A query that names a non-existent column and swallows the error looks like "no results".** iOS global search and the locked-chats list were empty for weeks. Log query failures.

---

## 10. Pending work

### Next on EC2 (owner, planner gives commands)
1. **Maintenance window (tonight / quiet time)** — `docs/deploy/maintenance-window.md`: (1) `stop_grace_period` 60 s for postgres/scylla/kafka, (2) Caddy recreate with directory mounts (fixes the missing `assetlinks.json` source), (3) reboot, then verify every service (incl. profiled) and all 7 SHAs. Until done: no Caddy restart, no reboot, no bare `up -d`.
2. **APNs key** once the membership is active (§7 Apple).
3. **Part 4** (15-min login access token) — unblocked by web `f1cf618`; confirm web refresh in an incognito session first, then a small auth slice + deploy.
4. Check the old volume `growblic-site_growblic-leads` for leads (read-only command from the Air).
5. Set `RESEND_API_KEY` (verified sender domain) so the contact form emails.

### Blocking the Play upload
1. **Delete account URL** → Play Console → App content → Data safety: `https://www.growblic.com/delete-account` (live, 200).
2. Rebuild the AAB on current Android main (the vc43 AAB predates the 22–23 Sep fixes).
3. POCO has no app installed — Developer options → **Install via USB**, then `adb shell pm verify-app-links --re-verify com.growblic.exway`.
4. Play Console: privacy policy URL, data safety form, content rating, listing + screenshots, grievance officer (IT Rules), ACCESS_BACKGROUND_LOCATION review with video.
5. `assetlinks.json` needs Google's app-signing SHA-256 from Play Console.
6. 16 KB runtime proof on a real 16 KB device from internal testing (static is 22/22).

### Blocking the App Store submission
1. Membership activation → Slice 7b → TestFlight.
2. `docs/APPSTORE.md`: pick a ≤30-char subtitle; export compliance answer (owner's call; app uses libsodium + AES-GCM, standard algorithms only).
3. Support URL on growblic.com (`/support` does not exist yet).
4. Real-iPhone batch.

### Queues by machine
| Machine | Queue |
|---|---|
| **mini – iOS** | Slice 15 Batches 2–5 → 7b (after activation) → real-iPhone batch |
| **mini – Android** | Device checks when phones are attached: account deletion on `+15550199004`; @guru key publish on the POCO; Android↔iOS E2EE with @growblic01; `tz_offset_minutes` on message create (prompt written); `UnreadDividerTest` red |
| **Air – docs** | Commit `docker-compose.selfhost.yml` + README + `.env.example` to growblicwebsite; `GROWBLIC-METHOD.md` updates (iOS row, rules 26/27); merge the thumbhash amendment (`exway-android/docs/e2ee-frame-amendment-thumbhash.md`) into `E2EE_FRAME.md` |
| **Air – backend backlog** | VoIP stale-ring cutoff (`apns-expiration` + a timestamp; iOS must report every VoIP push to CallKit) · change-number endpoint · "who can add me to groups" privacy setting (`contacts` must mean `shares_conversation?` or pick another middle value) · conversation-less call start (ad-hoc group calls) · `GET /keys/users` self key status (visible / revoked / missing) · Scylla date cursor for jump-to-date · **Scylla backup** (`nodetool snapshot` + schema `DESCRIBE`, copy off, `clearsnapshot`; path resolution untested) · `/admin/health` 404 on prod · 20 undocumented `/v1` routes · `get_conversation` reads settings 4× · key-rotation push |
| **Air – web** | Web view-once placeholder; web turn-on tiles; delete/decline UX polish |

### Real bugs, open
- **Inbox unread RECOUNT path** recounts from empty PG → 0 (maintained counter is fine).
- **Duplicate-row race on send** — echo/ack race still open (Android now sends `client_msg_id`, which should close most of it — re-check).
- Video/voice bubbles announce as "Photo" to accessibility (Android).
- Matches: `pref_require_shared_turn_on` ON for 3/4 prod profiles, source unidentified.
- `XandraBootLogTest` latent flake; `object_key` exposes owner id + filename.
- @guru (POCO) has no published device keys → its chats stay plaintext; root cause unproven.

### Product notes (owner decisions)
- **Punjabi**: no on-device model for translation or transcription; a server API with consent (plain chats only) is the only path.
- Written Hinglish can't be translated on-device; spoken Hinglish transcribes fine.
- FCM on non-whitelisted OEM builds can be Doze-deferred.
- Nearby Tester code: rotated 23 Sep; deleting the entry beats rotating if the account is spare.

### Parked / deferred
- **AI-generated chat wallpapers** — parked by the owner (15 Sep); Air inspect prompt written, not run.
- **Group E2EE** — sender keys (Option B), deferred; server refuses sealed in groups today.
- **SMS Retriever OTP auto-fill** — OFF until DLT template `1477178966975013590` is approved; then set `SMS_TEMPLATE_LOGIN_ID` and `SMS_RETRIEVER_APP_HASHES=68PGts+WCBC` (debug hash only; Play build needs a second template with `ULFu0JUOYhW`).
- **Orphan media sweep** — needs a Scylla `messages_by_media` probe before any delete.

---

## 11. The decrypt-on-ingest design (shipped `343b87f` — reference for the sealed receive path)

Measured 13 Sep, before the fix: live DM-open stub = 43–111 ms flash; backlog-on-resume serial at ~145 ms/message → 15 unread = 2.2 s tail. Keys cached in Room (24 h staleness, prefetch on chat open). Each id processed twice (user + conversation topic).

Built (client-only):
1. Decrypt inline on the socket `message_created` path **before** the Room insert when the peer key is cached; cache miss → insert pending.
2. Backlog pass: group by sender device, bounded-concurrent `openSealed`, **one batched Room update** per pass.
3. Dedup by id before `openSealed`.
4. Stub paints only if still pending ≥ 200 ms after first compose.
5. Prefetch peer keys on inbox load.

iOS mirrors this (Slice 4 + Slice 15 Batch 1: 8-at-a-time batches, skip already-decrypted rows, retry failed rows on chat open).

---

## 12. Useful diagnostics (EC2)

```bash
# Per-endpoint latency table from gateway logs (48 h): count, p50, p95, max, and non-2xx
docker compose -f docker-compose.prod.yml logs --since 48h gateway 2>&1 | awk '
  { rid=""; if (match($0,/"request_id":"[^"]*"/)) rid=substr($0,RSTART+14,RLENGTH-15) }
  rid!="" && match($0,/"message":"(GET|POST|PUT|PATCH|DELETE) [^"]*"/) {
      p=substr($0,RSTART+11,RLENGTH-12); gsub(/[0-9a-f]{8}-[0-9a-f-]{27}/,":id",p); gsub(/[A-Za-z0-9_-]{30,}/,":tok",p); path[rid]=p; next }
  rid!="" && (rid in path) && match($0,/"message":"Sent [0-9]+ in [0-9.]+[^"]*"/) {
      s=substr($0,RSTART,RLENGTH); split(s,a," "); d=a[4]; gsub(/"/,"",d);
      if (d ~ /s$/ && d !~ /ms$/) { sub(/[^0-9.]+$/,"",d); d=d/1000 } else { sub(/ms$/,"",d) }
      print path[rid], a[2], d; delete path[rid] }
' > /tmp/gw_lat.txt
python3 - <<'EOF'
import collections
d=collections.defaultdict(list); st=collections.Counter()
for l in open('/tmp/gw_lat.txt'):
    p,s,ms=l.strip().rsplit(' ',2); d[p].append(float(ms)); st[(p,s)]+=1
rows=[(len(v),p,sorted(v)[len(v)//2],sorted(v)[max(0,int(len(v)*0.95)-1)],max(v)) for p,v in d.items()]
rows.sort(key=lambda r:-r[0]*r[2])
for n,p,p50,p95,mx in rows[:40]: print(f"{n:6d} {p50:8.1f} {p95:8.1f} {mx:8.1f}  {p}")
for (p,s),c in sorted(st.items(), key=lambda x:-x[1]):
    if not s.startswith('2') and c>=3: print(c, s, p)
EOF

# Refresh failures in the last 10 min (real users vs your own checks)
docker compose -f docker-compose.prod.yml logs --since 10m auth gateway 2>/dev/null | grep -ciE "refresh_invalid|refresh_reused"

# Status of one request id
docker compose -f docker-compose.prod.yml logs --since 2h gateway 2>&1 | grep -E '<request_id>' | grep -oE '"message":"[^"]*"'

# FCM outcomes
docker compose -f docker-compose.prod.yml logs --since 3m notification 2>&1 | grep -oE '"message":"fcm [^"]*"'

# user_updated outcomes
docker compose -f docker-compose.prod.yml logs --since 3m gateway 2>&1 | grep -oE '"message":"user_updated [^"]*"'

# Tokens for a user (now with kind/environment)
docker compose -f docker-compose.prod.yml exec -T postgres psql -U chat_user -d chat_platform -c \
  "SELECT left(token,8) tok, device_id, kind, environment, updated_at FROM fcm_tokens WHERE user_id::text LIKE '<prefix>%';"

# Real users vs external end-users vs missing cards
docker compose -f docker-compose.prod.yml exec -T postgres psql -U chat_user -d chat_platform -c "
SELECT (external_id IS NOT NULL) AS external, (up.user_id IS NOT NULL) AS has_profile,
       EXISTS (SELECT 1 FROM device_sessions ds WHERE ds.user_id=ua.id) AS ever_logged_in, count(*)
FROM users_auth ua LEFT JOIN user_profiles up ON up.user_id=ua.id WHERE ua.status='active' GROUP BY 1,2,3 ORDER BY 1,2,3;"

# Caddy: what's mounted, and is the running config the working-tree file?
docker inspect chat-platform-prod-caddy-1 --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'
md5sum infra/caddy/Caddyfile; docker compose -f docker-compose.prod.yml exec -T caddy md5sum /etc/caddy/Caddyfile

# AASA body check (status alone lies)
curl -si https://web.growblic.com/.well-known/apple-app-site-association | grep -iE "^HTTP|content-type|content-length"

# Disk before a big build
df -h / && docker system df

# Auto-reply decisions / request counts / rate-limit buckets
docker compose -f docker-compose.prod.yml logs --since 2h gateway 2>&1 | grep -F '[auto_reply]'
docker compose -f docker-compose.prod.yml logs --since 2h gateway 2>&1 \
  | grep -oE '"message":"(GET|POST|PUT|PATCH|DELETE) [^"]*"' | sort | uniq -c | sort -rn | head -15
docker compose -f docker-compose.prod.yml exec -T redis redis-cli \
  MGET rate_limit:keys_fetch:<user_id> rate_limit:message_send:<user_id> rate_limit:rt:write:user:<user_id>
```

---

## 13. How to phrase prompts (what works)

- **State the evidence, not just the ask.** Paste log lines, measured numbers, file:line.
- **Name the mutations explicitly** (backend/Android) and require the RED paste; for iOS, keep testing basic per the owner.
- **Two phases for anything unfamiliar.** "INSPECT, report, STOP" then "BUILD after I read it."
- **Measure first.**
- **Say what NOT to do.** Scope creep is the default failure mode.
- **Ask for the honest limit** and the honest premise check ("if the premise doesn't hold, STOP").
- **Demand that every outcome logs** as part of the build.
- **Pin the non-bug as an invariant test** when an inspect finds nothing to fix.
- **Ratify judgement calls explicitly** — including when the agent corrects the planner (it has been right several times: sign-out wipe semantics, `user_asset` being internal-only, the TestFlight APNs environment).
- **Give the EC2 block in the recipe's shape** (`--no-deps --force-recreate`, `GIT_SHA`, verify lines, checkpoints where the owner pastes output before continuing). Agents write `docker exec <container-name>` and bare `up -d` — fix it before pasting.
- **Large iOS work goes in batches** (5 batches for Slice 15), each ending in push + short report + wait for "go".
- **Combined multi-part prompts work** when each part reports before the next starts and the push is at the very end. When the owner asks "sab ek prompt me", give one prompt per machine plus a table of where each goes.
