# Uptime monitoring

**Why this exists.** On 2026-09-23 prod was down for **9.5 hours** and nothing told anybody. The
runbook had a post-reboot check; the operator had gone to bed. A check that needs a human awake is
not a check. This is the external one. (Handoff §9 rule 33.)

## The recommendation: a hosted monitor (UptimeRobot free tier)

Not a GitHub Actions cron, for three reasons that all matter more than the convenience of keeping it
in the repo:

* **The minute budget.** Actions is free for public repos; `chat-platform` is **private**, so it
  draws on the 2,000 minutes/month allowance. A 5-minute schedule is 8,640 runs a month and every run
  is billed at a 1-minute minimum — roughly 4× the allowance. The monitor would stop partway through
  the month, and stop silently.
* **Scheduled workflows are disabled after ~60 days without repository activity.** A monitor that
  switches itself off during a quiet period is the exact failure class this incident is about.
* **`schedule:` is best-effort.** Runs are routinely delayed 10–30 minutes at peak, so detection
  latency is unpredictable in the direction you care about.

A hosted monitor has none of those, needs no secrets in the repo, and takes about ten minutes to set
up. UptimeRobot's free tier (50 monitors, 5-minute interval, email alerts) is the usual choice;
Better Stack, Pingdom and Hetrix have comparable tiers. **Check the current free-tier limits when you
sign up** — they change, and this file will not.

## Setup — do this once

### 1. Account

Sign up at <https://uptimerobot.com> with an address you actually read on your phone. Confirm the
email before continuing, or no alert will ever arrive.

### 2. The three monitors

**Dashboard → + New monitor.** Create all three. Interval **5 minutes** on all of them.

| # | Monitor type | URL | Expect |
|---|---|---|---|
| 1 | **Keyword** | `https://api.growblic.com/health` | keyword `"status":"ok"` **exists** |
| 2 | HTTP(s) | `https://web.growblic.com/login` | 200 |
| 3 | HTTP(s) | `https://www.growblic.com/` | 200 |

Name them `growblic api`, `growblic web`, `growblic www` so the alert subject says which one.

Three notes on the choices, each learned from a wrong check in the runbooks:

* **Monitor 1 is a keyword monitor, not a plain HTTP one.** Caddy answers `502` when the gateway is
  down, which a status-code check would catch — but a keyword check also catches a `200` that is not
  actually healthy. The body is
  `{"status":"ok","service":"api_gateway","git_sha":"…"}`.
* **`/login`, not `/`, for web.** `https://web.growblic.com/` returns **307** to `/login`.
  UptimeRobot follows redirects, so `/` would work too, but pointing at the final 200 removes a
  moving part.
* **Do not monitor `media.growblic.com`.** It has no unauthenticated endpoint that returns 200 —
  `/health` is **403** on a healthy box. It is exercised by the app's presign path. Monitoring it
  would produce a permanent false alarm, which is how people learn to ignore alerts.

`www.growblic.com` is worth its own monitor even though it looks like marketing: it is a **separate
compose project** (`growblic-site`) with its own container and its own failure modes, and Caddy
fronts all three — one monitor per failure domain.

### 3. Alert contacts

**My settings → Add alert contact.** Add **two**:

1. **E-mail** — the address from step 1.
2. **Mobile push** — install the UptimeRobot app and add it as a contact. Email at 02:00 is a letter;
   push at 02:00 is an alarm. The outage was overnight; this is the one that would have caught it.

Then, on each of the three monitors: edit → **select both contacts** → set **"Notify when down"**
after **2 consecutive failures** (≈10 minutes' detection, and a single blip does not wake you) and
**"Notify when back up"** on.

> A contact added in *My settings* is **not** attached to existing monitors automatically. Open each
> monitor and tick it, or you will have three monitors and no alerts.

### 4. Prove the alert path works — do not skip this

An untested alert is not an alert; that is the whole lesson of this incident. Test it **without
touching prod**:

1. Edit monitor 2 (`growblic web`), change the URL to
   `https://web.growblic.com/definitely-not-a-route-9c3f`, save.
2. Wait ~10 minutes. **An email and a push must arrive**, naming `growblic web`.
3. Change the URL back to `https://web.growblic.com/login`, save.
4. Wait for the "back up" notification.

If nothing arrives: the contact is not attached to that monitor (step 3's warning), or the email is
unconfirmed, or it is in spam — fix it now, while you are looking at it.

### 5. Optional, and directly useful: a heartbeat for the nightly backup

`scripts/ops/pg-backup.sh` writes `OK`/`FAILED` to `~/backups/backup.log`, which only helps if
somebody reads it — and it cannot say anything at all if cron never fires or the box is down at
21:30 UTC. A heartbeat closes that: the job pings a URL when it succeeds, and the monitor alerts when
the ping does **not** arrive.

1. **+ New monitor → Heartbeat**, name `growblic pg-backup`, period **1 day**, grace **2 hours**.
   Copy the URL it gives you.
2. On the box, append the ping to the successful path:
   ```bash
   echo 'BACKUP_HEARTBEAT_URL=https://heartbeat.uptimerobot.com/XXXXXX' >> ~/.backup.env
   chmod 600 ~/.backup.env
   ```
   The script sources `~/.backup.env` if it exists and pings `BACKUP_HEARTBEAT_URL` **only on
   success** — so a failed or missing backup is a missed heartbeat, and you hear about it.

## When an alert fires

1. `curl -s https://api.growblic.com/health` — confirm it from your side; monitors do have false
   positives.
2. If it is real, get onto the box and run the **not-running check** from
   `docs/deploy/maintenance-window.md` step 3 ("Verify everything came back"). It names anything whose
   state is not `running` and the `compose start` that fixes it. That block is written to be the first
   thing you run half-asleep.
3. If everything is `running` but `/health` still fails, it is not a stopped-stack problem: check
   Caddy (`docker compose -f docker-compose.prod.yml ps caddy`) and the gateway logs.

## What this does not cover

* **Scylla, Kafka, the consumers.** `/health` proves the gateway answers, not that messages are being
  projected. Consumer lag is still a manual check (the runbooks' consumer-group block).
* **Certificate expiry.** Caddy renews automatically; a failure there would surface as an HTTPS error
  on all three monitors at once, which is the right signal but a late one.
* **The backup's contents.** The heartbeat proves it ran and passed its own checks, not that the dump
  restores. A restore rehearsal is still owed (roadmap).
