# Maintenance window — stop grace, Caddy mounts, reboot

One window, three changes, in this order. Each is a prerequisite for the next: the stop grace must be
**in effect before** the reboot or the reboot is exactly the event it cannot protect, and the Caddy
mounts land before the reboot so everything is verified once rather than twice.

Expect **20–30 minutes**, of which the reboot is ~2. Steps 1 and 2 recreate containers; those services
are down for seconds. Step 3 takes the whole box down.

**Before you start**, in the shell you will use throughout:

```bash
cd ~/chat-platform
git fetch origin && git pull --ff-only origin main
export EXPECTED=$(git rev-parse --short HEAD)
echo "window on: $EXPECTED"
git status --porcelain
```

`git status --porcelain` must print nothing. `$EXPECTED` is what step 3 verifies the app containers
against — if you open a new shell at any point, re-derive it here before continuing.

Record the starting state so you can tell what the window changed:

```bash
docker compose -f docker-compose.prod.yml --profile kafka --profile scylla --profile calls ps \
  --format '{{.Service}}\t{{.Status}}' | sort | tee ~/before-window.txt
uptime
cat /var/run/reboot-required.pkgs 2>/dev/null || echo "(no package list)"
```

> **Take the backups first.** `pg_dump` per step 2 of `docs/deploy/2026-09-23.md`. **There is still no
> Scylla backup** (Follow-up 1 in that doc), so message history is not covered by anything here. A
> reboot is precisely when an unclean shutdown can cost data, and this window is the strongest
> argument yet for closing that gap — consider doing it before this window rather than after.

---

## Step 1 — `stop_grace_period: 60s` on postgres, scylla and kafka

**Why.** No service in `docker-compose.prod.yml` sets one, so every container gets Docker's default
**10 seconds** before `SIGKILL`. For Postgres, Scylla and Kafka that is thin enough to mean WAL or
commitlog replay on the way back up, and in the worst case corruption. These three are the stateful
ones; the app services are stateless and 10 s is fine for them.

Edit the three services in `docker-compose.prod.yml`, adding one line to each at the same level as
`image:` and `restart:`:

```yaml
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    stop_grace_period: 60s
```

…and the same for `scylla:` and `kafka:`.

**Check the edit before applying it** — this is a YAML file that eleven services depend on:

```bash
git diff docker-compose.prod.yml
docker compose -f docker-compose.prod.yml config --services >/dev/null && echo "compose parses OK"
```

`git diff` must show exactly three added lines. If `config --services` errors, fix the YAML before
going further — nothing has been applied yet.

Apply. `stop_grace_period` only takes effect on a **recreated** container, so these three are
recreated now, one at a time so a failure is contained:

```bash
docker compose -f docker-compose.prod.yml up -d postgres
docker compose -f docker-compose.prod.yml --profile scylla up -d scylla
docker compose -f docker-compose.prod.yml --profile kafka up -d kafka
```

**Shows it worked** — the value is live on the container, not just in the file:

```bash
for c in postgres scylla kafka; do
  printf '%-10s StopTimeout=%s\n' "$c" \
    "$(docker inspect "$(docker compose -f docker-compose.prod.yml --profile kafka --profile scylla ps -q $c)" \
       --format '{{.Config.StopTimeout}}')"
done
```

All three must print `StopTimeout=60`. **`StopTimeout=<nil>` is the unset value** and means the
container was not recreated — re-run its `up -d`. (Verified: `stop_grace_period: 60s` in compose maps
to `.Config.StopTimeout` = `60`; a container without one inspects as `<nil>`, not `10` — the 10 s
default lives in the client, not on the container.)

Then confirm the stateful services are actually healthy again before touching anything else:

```bash
docker compose -f docker-compose.prod.yml exec -T postgres pg_isready -U chat_user -d chat_platform
docker compose -f docker-compose.prod.yml --profile scylla exec -T scylla cqlsh -e "describe cluster" >/dev/null && echo "scylla CQL OK"
docker compose -f docker-compose.prod.yml --profile kafka exec -T kafka \
  /opt/bitnami/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list | head -5
curl -s -o /dev/null -w 'api %{http_code}\n' https://api.growblic.com/health
```

Postgres `accepting connections`, Scylla `scylla CQL OK`, Kafka listing topics, api `200`.

> **A caveat that matters for step 3.** `stop_grace_period` governs `docker stop` / `compose stop`. On
> a host reboot the **Docker daemon** is what shuts the containers down, and it caps that wait with its
> own `--shutdown-timeout` (default **15 s**) regardless of any container's StopTimeout. So this change
> does **not** on its own make `sudo reboot` graceful. Check what the daemon is set to:
>
> ```bash
> cat /etc/docker/daemon.json 2>/dev/null || echo "(no daemon.json — defaults apply)"
> ps -o args= -C dockerd | tr ' ' '\n' | grep -i shutdown || echo "(no --shutdown-timeout flag)"
> ```
>
> Rather than editing the daemon config inside this window, step 3 stops the stack **explicitly** with
> a 60 s timeout before rebooting, which uses the StopTimeout you just set and needs no daemon change.
> Raising `--shutdown-timeout` is still worth doing separately, because an **unplanned** reboot gets no
> explicit stop.

**Rollback for step 1:**

```bash
git checkout HEAD -- docker-compose.prod.yml   # or: git checkout <SHA> -- docker-compose.prod.yml
docker compose -f docker-compose.prod.yml up -d postgres
docker compose -f docker-compose.prod.yml --profile scylla up -d scylla
docker compose -f docker-compose.prod.yml --profile kafka up -d kafka
```

Nothing persistent changed — the volumes are untouched, so this is a pure container-config revert.

---

## Step 2 — the Caddy recreate onto directory mounts

**Why.** The single-file bind mounts pin the file's inode at container start, so after a `git pull`
Caddy kept reading the old file and `caddy reload` reported success while reloading the **previous**
config. Directory mounts make every read a fresh directory lookup. This is the one-time recreate that
buys back validate + reload for every later deploy. Full background in `docs/deploy/2026-09-23.md`
step 6.

**Validate from disk first**, via a throwaway container. Not through the running Caddy — the running
Caddy is precisely what cannot see the pulled file:

```bash
docker run --rm -v "$PWD/infra/caddy:/etc/caddy:ro" caddy:2.8-alpine \
  caddy validate --config /etc/caddy/Caddyfile
```

Expect `Valid configuration`. **If it does not say that, stop.** Nothing has changed and the site is
still up.

Recreate:

```bash
docker compose -f docker-compose.prod.yml up -d caddy
docker compose -f docker-compose.prod.yml ps caddy --format '{{.Service}}\t{{.Status}}'
```

Caddy must read `Up …`, **not** `Restarting`.

**Shows it worked** — the md5 check is the whole point of this step:

```bash
echo "--- in container ---"
docker compose -f docker-compose.prod.yml exec -T caddy \
  md5sum /etc/caddy/Caddyfile /srv/.well-known/assetlinks.json
echo "--- on disk ---"
md5sum infra/caddy/Caddyfile infra/caddy/srv/.well-known/assetlinks.json
```

The two pairs must match. **If they do not, the container is on stale files** — do not proceed and do
not trust any reload.

Then the served endpoints, reading bodies rather than status codes:

```bash
curl -sS -D- https://web.growblic.com/.well-known/apple-app-site-association \
  | grep -iE "^HTTP/|^content-type|^content-length"
curl -sS https://web.growblic.com/.well-known/apple-app-site-association | python3 -m json.tool
curl -sS -o /dev/null -w 'assetlinks %{http_code} %{content_type} %{size_download}\n' \
  https://web.growblic.com/.well-known/assetlinks.json
for h in api.growblic.com web.growblic.com media.growblic.com; do
  printf '%-22s %s\n' "$h" "$(curl -s -o /dev/null -w '%{http_code}' https://$h/health 2>/dev/null || echo ERR)"
done
```

AASA: `200`, `application/json`, **`content-length: 118`** (not 0), and `json.tool` parses it.
assetlinks: `200 application/json` and a **non-zero** size — it changed directory in this deploy, so
this is not a formality.

**Rollback for step 2:**

```bash
git checkout HEAD -- infra/caddy/ docker-compose.prod.yml
docker compose -f docker-compose.prod.yml up -d caddy
docker compose -f docker-compose.prod.yml exec -T caddy md5sum /etc/caddy/Caddyfile
md5sum infra/caddy/Caddyfile
curl -s -o /dev/null -w 'api %{http_code}\n' https://api.growblic.com/health
```

If Caddy is **restart-looping** it cannot be `exec`-ed into, so validate and reload are unavailable —
restore the files on disk and `docker compose -f docker-compose.prod.yml restart caddy`, then read
`logs --tail=30 caddy`.

---

## Step 3 — reboot the box

**Stop the stack explicitly first.** This is what makes the reboot graceful: it uses the 60 s
StopTimeout from step 1, which the daemon's own shutdown would otherwise cap at ~15 s. Name every
profile or the profiled services are not included:

```bash
docker compose -f docker-compose.prod.yml \
  --profile kafka --profile scylla --profile calls stop --timeout 60
docker compose -f docker-compose.prod.yml \
  --profile kafka --profile scylla --profile calls ps --format '{{.Service}}\t{{.Status}}'
```

Every service must read `Exited (0)`. An `Exited (137)` is a `SIGKILL` — the process did not stop in
time. Note which one; it is the one to watch on the way back up.

```bash
sudo reboot
```

Reconnect after a minute or two.

### Verify everything came back

Restart policies do the work: all eleven services are `restart: unless-stopped`, and **profiles do not
affect this** — a profile is a compose-CLI concept while the restart policy belongs to the container,
so `scylla`, `kafka`, `kafka-init`, `notification` and `livekit` come back without being named. Verify
that rather than assume it:

```bash
cd ~/chat-platform
uptime                     # confirm it actually rebooted
docker compose -f docker-compose.prod.yml --profile kafka --profile scylla --profile calls ps \
  --format '{{.Service}}\t{{.Status}}' | sort | tee ~/after-window.txt
diff ~/before-window.txt ~/after-window.txt && echo "same service set as before the window"
```

Every service `Up`, none `Restarting`. `kafka-init` and `minio-init` are one-shot jobs and correctly
read `Exited (0)` — that is not a failure.

Give the stateful services a moment, then check them directly:

```bash
docker compose -f docker-compose.prod.yml exec -T postgres pg_isready -U chat_user -d chat_platform
docker compose -f docker-compose.prod.yml --profile scylla exec -T scylla cqlsh -e "describe cluster" >/dev/null && echo "scylla CQL OK"
docker compose -f docker-compose.prod.yml --profile kafka exec -T kafka \
  /opt/bitnami/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list | head -5
```

Scylla is the slow one — `start_period` is 90 s and a commitlog replay makes it longer. If `cqlsh`
refuses, wait and retry before concluding anything.

### The seven app containers still report `$EXPECTED`

A reboot restarts containers from their existing images, so this should be unchanged — which is the
point. It catches an image having been rebuilt or rolled back mid-window without you noticing:

```bash
[ -n "$EXPECTED" ] || echo "EXPECTED is unset — re-derive: export EXPECTED=$(git rev-parse --short HEAD)"
for s in gateway auth conversation user message media notification; do
  got=$(docker compose -f docker-compose.prod.yml --profile kafka exec -T "$s" sh -c 'echo $GIT_SHA' | tr -d '\r')
  if [ "$got" = "$EXPECTED" ]; then verdict=OK; else verdict="MISMATCH (expected $EXPECTED)"; fi
  printf '%-14s %-12s %s\n' "$s" "$got" "$verdict"
done
```

All seven must read `OK`.

### The endpoints

```bash
for h in api.growblic.com web.growblic.com media.growblic.com; do
  printf '%-22s %s\n' "$h" "$(curl -s -o /dev/null -w '%{http_code}' https://$h/health 2>/dev/null || echo ERR)"
done
curl -sS -o /dev/null -w 'AASA       %{http_code} %{content_type} %{size_download}\n' \
  https://web.growblic.com/.well-known/apple-app-site-association
curl -sS -o /dev/null -w 'assetlinks %{http_code} %{content_type} %{size_download}\n' \
  https://web.growblic.com/.well-known/assetlinks.json
```

AASA `200 application/json 118`, assetlinks `200 application/json` non-zero, the three hosts `200`.

Finally, read the logs for anything that came back unhappy — a service can be `Up` and still be
failing on every request:

```bash
docker compose -f docker-compose.prod.yml --profile kafka --profile scylla --profile calls \
  logs --since 10m | grep -iE "error|CRASH|Kernel pid|corrupt|replay" | head -30
```

Commitlog or WAL **replay** messages on Scylla or Postgres are expected after a restart and are not by
themselves a problem. `corrupt` is.

**Rollback for step 3.** A reboot cannot be undone. If a service does not come back:

```bash
docker compose -f docker-compose.prod.yml --profile kafka --profile scylla --profile calls \
  logs --tail=100 <service>
docker compose -f docker-compose.prod.yml --profile kafka --profile scylla --profile calls \
  up -d <service>
```

If Postgres will not start, that is what `~/predeploy-*.sql.gz` and the full-restore section of
`docs/deploy/2026-09-23.md` are for. If **Scylla** will not start, there is **no backup to restore
from** — do not delete the `scylla_data` volume to "fix" it. Capture the logs and stop.

---

## Checked in this window: `assetlinks.json` is missing Google's app-signing SHA-256

**What is served today** — one fingerprint, for `com.growblic.exway`:

```
A3:CE:01:F7:CA:AB:A8:A0:E7:E3:28:FB:DD:36:92:17:32:79:15:12:7B:A9:07:F0:27:80:D6:1F:12:44:2B:BC
```

`infra/caddy/Caddyfile` records what that is: *"THE FINGERPRINT IN assetlinks.json BELONGS TO THE
RELEASE KEYSTORE."*

**Why that is a problem under Play App Signing.** When an app is enrolled, you upload a build signed
with your **upload key** and Google **re-signs** it with a different **app-signing key**. The APK users
actually install therefore carries Google's fingerprint, not the release keystore's. Android verifies
App Links against the fingerprint of the **installed** app — so if only the keystore fingerprint is
listed, verification fails for every Play-installed build and deep links fall back to the chooser
dialog. There is no server-side error; the endpoint keeps serving `200` and looking healthy, which is
why this has gone unnoticed.

**So: yes, still missing** — assuming the app is enrolled in Play App Signing, which is the default for
new apps and cannot be confirmed from this repo. Confirm and fix in Play Console:

* **Release → Setup → App signing.** If the page shows an *App signing key certificate*, the app is
  enrolled. Copy its **SHA-256**. (The *Upload key certificate* on the same page is the one likely
  already listed.)
* Add it **alongside** the existing fingerprint rather than replacing it — `sha256_cert_fingerprints`
  is a list, and keeping both means locally-built release APKs keep verifying too.

The edit itself is a one-line change to `infra/caddy/srv/.well-known/assetlinks.json` and, **after this
window's step 2**, ships with a plain validate + reload and no recreate. Verify with Google's own
checker rather than by eye, since Android caches verification aggressively:

```
https://digitalassetlinks.googleapis.com/v1/statements:list?source.web.site=https://web.growblic.com&relation=delegate_permission/common.handle_all_urls
```

Not done here: it needs a value only the Play Console can give, and this window is deliberately about
infrastructure rather than app configuration. Backlogged in `docs/03-roadmap/ROADMAP.md`.
