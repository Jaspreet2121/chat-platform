#!/usr/bin/env bash
#
# Nightly Postgres backup for growblic prod. Canonical copy lives here; ~/bin/pg-backup.sh on EC2 is
# an installed copy. Cron is unchanged: 30 21 * * *  ->  ~/bin/pg-backup.sh
#
# INSTALL / UPDATE ON EC2 (one command — pulls, keeps the old script, installs, runs once, shows the log):
#
#   cd ~/chat-platform && git pull --ff-only origin main && mkdir -p ~/bin \
#     && { cp ~/bin/pg-backup.sh ~/bin/pg-backup.sh.bak-$(date +%F) 2>/dev/null || true; } \
#     && install -m 755 scripts/ops/pg-backup.sh ~/bin/pg-backup.sh \
#     && ~/bin/pg-backup.sh && tail -3 ~/backups/backup.log
#
# WHY THIS SCRIPT IS SHAPED LIKE THIS. On 2026-09-23 the previous version wrote a 20-byte file and
# said nothing: Postgres was stopped (see handoff §9 rule 33), `pg_dump` failed, and `gzip` cheerfully
# compressed the empty stream and exited 0. In a plain `a | b > file` pipeline the shell reports only
# b's status, so the job "succeeded" every night it failed. Every guard below exists for that:
#
#   * `pipefail` + PIPESTATUS   — pg_dump's own exit code is read, not gzip's.
#   * a minimum size            — an empty or error-only dump is not a backup.
#   * `gzip -t` and a header check — catches a dump that died HALFWAY, which is big enough to pass a
#                                 size check and is still unusable.
#   * write to .tmp, then mv    — the previous good backup is never replaced by a bad one.
#   * retention only on success — otherwise a run of silent failures eventually deletes the last
#                                 good backup too.
#   * OK/FAILED + reason to backup.log, and a non-zero exit.
#
# NOT `set -e`: on failure this script must live long enough to WRITE that it failed.
set -uo pipefail

# cron gets a near-empty PATH and would not find `docker`.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

COMPOSE_FILE="${COMPOSE_FILE:-$HOME/chat-platform/docker-compose.prod.yml}"
PG_SERVICE="${PG_SERVICE:-postgres}"
PG_USER="${PG_USER:-chat_user}"
PG_DB="${PG_DB:-chat_platform}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
# 100 KB. The real dump is megabytes; the failure mode was 20 bytes.
MIN_BYTES="${MIN_BYTES:-102400}"

# Optional: a heartbeat URL pinged ONLY on success, so a backup that never ran at all is a missed
# ping rather than silence. See docs/09-devops/UPTIME_MONITORING.md step 5.
[ -f "$HOME/.backup.env" ] && . "$HOME/.backup.env"
BACKUP_HEARTBEAT_URL="${BACKUP_HEARTBEAT_URL:-}"

mkdir -p "$BACKUP_DIR" || { echo "pg-backup: cannot create $BACKUP_DIR" >&2; exit 1; }

# `wc -c` pads with spaces on some platforms; strip it so the log line stays parseable.
size_of() { wc -c < "$1" 2>/dev/null | tr -d '[:space:]' || echo 0; }

LOG="$BACKUP_DIR/backup.log"
STAMP="$(date -u +%F)"
TARGET="$BACKUP_DIR/chat_platform-$STAMP.sql.gz"
TMP="$TARGET.tmp"
ERR="$(mktemp)"

# Every exit goes through here: one line, always, to the log and to stdout (so a hand-run shows it).
finish() {
  status="$1"; reason="$2"; bytes="${3:-0}"
  line="$(date -u +'%F %T UTC')  $status  file=$(basename "$TARGET")  bytes=$bytes  $reason"
  printf '%s\n' "$line" >> "$LOG"
  printf '%s\n' "$line"
  rm -f "$TMP" "$ERR"
  [ "$status" = "OK" ] && exit 0
  exit 1
}

# --- the dump ------------------------------------------------------------------------------------
docker compose -f "$COMPOSE_FILE" exec -T "$PG_SERVICE" \
  pg_dump -U "$PG_USER" -d "$PG_DB" --no-owner --no-acl 2>"$ERR" | gzip -9 > "$TMP"
rc=("${PIPESTATUS[@]}")          # captured IMMEDIATELY; any other command would clobber it
dump_rc="${rc[0]}"
gzip_rc="${rc[1]}"

if [ "$dump_rc" -ne 0 ]; then
  # First line of stderr only: enough to diagnose, and it keeps credentials/hostnames out of the log.
  finish FAILED "pg_dump exit=$dump_rc: $(head -1 "$ERR" | cut -c1-200)" "$(size_of "$TMP")"
fi

[ "$gzip_rc" -ne 0 ] && finish FAILED "gzip exit=$gzip_rc" "$(size_of "$TMP")"

# --- is it actually a backup? --------------------------------------------------------------------
bytes="$(size_of "$TMP")"

[ "$bytes" -lt "$MIN_BYTES" ] && \
  finish FAILED "too small: $bytes bytes < $MIN_BYTES (previous backup kept)" "$bytes"

gzip -t "$TMP" 2>/dev/null || \
  finish FAILED "gzip integrity check failed — truncated dump (previous backup kept)" "$bytes"

# Read the header into a VARIABLE rather than `… | head -5 | grep -q`. Under `pipefail`, `head`
# closing the pipe early makes gunzip exit 141 (SIGPIPE) and the whole pipeline "fail" even when grep
# matched — which would have rejected every good backup, nightly, and kept promoting nothing. The
# flag that fixes a silent success creates a silent failure if you let it. Command substitution's
# status is not checked here, so the match is all that decides.
header="$(gunzip -c "$TMP" 2>/dev/null | head -5)"
case "$header" in
  *"PostgreSQL database dump"*) : ;;
  *) finish FAILED "not a pg_dump header — wrong content (previous backup kept)" "$bytes" ;;
esac

# --- promote, then prune -------------------------------------------------------------------------
mv -f "$TMP" "$TARGET" || finish FAILED "could not move $TMP into place" "$bytes"

# Retention runs ONLY after a good backup, so a run of failures can never delete the last good one.
deleted="$(find "$BACKUP_DIR" -maxdepth 1 -name 'chat_platform-*.sql.gz' -mtime "+$RETENTION_DAYS" -print -delete 2>/dev/null | wc -l | tr -d ' ')"

if [ -n "$BACKUP_HEARTBEAT_URL" ]; then
  curl -fsS --max-time 20 "$BACKUP_HEARTBEAT_URL" >/dev/null 2>&1 \
    || printf '%s\n' "$(date -u +'%F %T UTC')  WARN  heartbeat ping failed (backup itself is fine)" >> "$LOG"
fi

finish OK "pruned=$deleted retention=${RETENTION_DAYS}d" "$bytes"
