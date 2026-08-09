"use client";

import { useCallback, useEffect, useState } from "react";
import { Activity, CheckCircle2, Loader2, RefreshCw } from "lucide-react";
import {
  EventOutboxRow,
  EventOutboxRowDetail,
  EventOutboxStateSummary,
  acknowledgeEventOutboxRow,
  getAdminEventOutboxRow,
  getAdminEventOutboxRows,
  getAdminEventOutboxSummary,
  getCurrentSession
} from "@/lib/api";
import { Button, Card } from "@/components";

// Event-outbox ops (096) — the webhook dead-letter page's sibling, adapted where the semantics
// differ: nothing here retries or republishes (the relay is the only publisher). Reads are
// webhooks.view; the single mutation — acknowledge, aborted-only, one-way — is webhooks.manage,
// and we hide the button for viewers without it. The envelope renders ONLY behind the per-row
// expand; it is ids-only by the topic's thin-payload design, never message content.

const STATES = ["aborted", "pending", "staged", "acknowledged"] as const;
type OutboxState = (typeof STATES)[number];

// staged older than ~90s (stale window 60s + sweep interval 30s) means the relay is not resolving.
const STAGED_ANOMALY_SECONDS = 90;

function formatTime(iso?: string | null): string {
  if (!iso) return "—";
  const parsed = new Date(iso);
  return Number.isNaN(parsed.getTime()) ? "—" : parsed.toLocaleString();
}

function formatAge(seconds: number): string {
  if (!seconds) return "—";
  if (seconds < 120) return `${seconds}s`;
  if (seconds < 7200) return `${Math.round(seconds / 60)}m`;
  return `${Math.round(seconds / 3600)}h`;
}

export default function AdminEventsPage() {
  const [summary, setSummary] = useState<EventOutboxStateSummary | null>(null);
  const [state, setState] = useState<OutboxState>("aborted");
  const [rows, setRows] = useState<EventOutboxRow[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [expanded, setExpanded] = useState<EventOutboxRowDetail | null>(null);
  const [canManage, setCanManage] = useState(false);
  const [error, setError] = useState("");
  const [isLoading, setIsLoading] = useState(true);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [busyId, setBusyId] = useState<string | null>(null);

  useEffect(() => {
    getCurrentSession()
      .then((session) => setCanManage((session.permissions ?? []).includes("webhooks.manage")))
      .catch(() => setCanManage(false));
  }, []);

  const load = useCallback(
    async (opts: { append?: boolean; cursor?: string } = {}) => {
      if (opts.append) setIsLoadingMore(true);
      else setIsLoading(true);
      try {
        const [nextSummary, page] = await Promise.all([
          getAdminEventOutboxSummary(),
          getAdminEventOutboxRows({ status: state, cursor: opts.cursor, limit: 50 })
        ]);
        setSummary(nextSummary);
        setRows((prev) => (opts.append ? [...prev, ...page.data] : page.data));
        setCursor(page.next_cursor ?? null);
        setError("");
      } catch (caught) {
        setError(caught instanceof Error ? caught.message : "Failed to load the event outbox.");
      } finally {
        setIsLoading(false);
        setIsLoadingMore(false);
      }
    },
    [state]
  );

  useEffect(() => {
    setExpanded(null);
    void load();
  }, [load]);

  const expand = async (id: string) => {
    try {
      setExpanded(await getAdminEventOutboxRow(id));
      setError("");
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Failed to load the row.");
    }
  };

  const acknowledge = async (id: string) => {
    setBusyId(id);
    try {
      await acknowledgeEventOutboxRow(id);
      setExpanded(null);
      await load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Acknowledge failed.");
    } finally {
      setBusyId(null);
    }
  };

  const stagedAnomalous =
    (summary?.staged.max_age_seconds ?? 0) > STAGED_ANOMALY_SECONDS;

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h1 className="flex items-center gap-2 text-lg font-semibold">
          <Activity className="h-5 w-5" /> Event outbox
        </h1>
        <Button variant="ghost" onClick={() => void load()} disabled={isLoading}>
          {isLoading ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />}
          Refresh
        </Button>
      </div>

      {/* Zeros mean health: published rows are deleted on broker ack. */}
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Card className="p-3">
          <div className="text-xs text-faint">Aborted (incidents)</div>
          <div className="text-xl font-semibold">{summary?.aborted.count ?? "—"}</div>
        </Card>
        <Card className="p-3">
          <div className="text-xs text-faint">Pending (broker)</div>
          <div className="text-xl font-semibold">
            {summary?.pending.count ?? "—"}
            <span className="ml-2 text-xs font-normal text-faint">
              max {formatAge(summary?.pending.max_age_seconds ?? 0)}
            </span>
          </div>
        </Card>
        <Card className={`p-3 ${stagedAnomalous ? "border-red-500" : ""}`}>
          <div className="text-xs text-faint">
            Staged {stagedAnomalous ? "· RELAY NOT RESOLVING" : ""}
          </div>
          <div className="text-xl font-semibold">
            {summary?.staged.count ?? "—"}
            <span className="ml-2 text-xs font-normal text-faint">
              max {formatAge(summary?.staged.max_age_seconds ?? 0)}
            </span>
          </div>
        </Card>
        <Card className="p-3">
          <div className="text-xs text-faint">Acknowledged (filed)</div>
          <div className="text-xl font-semibold">{summary?.acknowledged.count ?? "—"}</div>
        </Card>
      </div>

      <div className="flex gap-2">
        {STATES.map((candidate) => (
          <Button
            key={candidate}
            variant={candidate === state ? "primary" : "ghost"}
            onClick={() => setState(candidate)}
          >
            {candidate}
          </Button>
        ))}
      </div>

      {error ? <div className="text-sm text-red-500">{error}</div> : null}

      <Card className="divide-y divide-border">
        {rows.length === 0 && !isLoading ? (
          <div className="p-4 text-sm text-faint">No {state} rows — for this table, empty is healthy.</div>
        ) : null}
        {rows.map((row) => (
          <div key={row.id} className="flex items-center gap-3 p-3 text-sm">
            <button className="flex-1 text-left" onClick={() => void expand(row.id)}>
              <div className="font-medium">{row.event_type}</div>
              <div className="text-xs text-faint">
                conv {row.conversation_id.slice(0, 8)} · msg {row.message_id.slice(0, 8)} ·{" "}
                {formatTime(row.created_at)}
                {row.attempts > 0 ? ` · ${row.attempts} attempts` : ""}
              </div>
              {row.last_error ? (
                <div className="mt-1 truncate text-xs text-red-500">{row.last_error}</div>
              ) : null}
            </button>
            {canManage && row.status === "aborted" ? (
              <Button
                variant="ghost"
                onClick={() => void acknowledge(row.id)}
                disabled={busyId === row.id}
              >
                {busyId === row.id ? (
                  <Loader2 className="h-4 w-4 animate-spin" />
                ) : (
                  <CheckCircle2 className="h-4 w-4" />
                )}
                Acknowledge
              </Button>
            ) : null}
          </div>
        ))}
      </Card>

      {cursor ? (
        <Button
          variant="ghost"
          onClick={() => void load({ append: true, cursor })}
          disabled={isLoadingMore}
        >
          {isLoadingMore ? <Loader2 className="h-4 w-4 animate-spin" /> : null}
          Load more
        </Button>
      ) : null}

      {expanded ? (
        <Card className="space-y-2 p-4 text-sm">
          <div className="flex items-center justify-between">
            <div className="font-semibold">
              {expanded.event_type} · {expanded.status}
            </div>
            <Button variant="ghost" onClick={() => setExpanded(null)}>
              Close
            </Button>
          </div>
          <div className="text-xs text-faint">
            topic {expanded.topic} · key {expanded.partition_key} · {formatTime(expanded.created_at)}
          </div>
          {expanded.last_error ? (
            <div className="text-xs text-red-500">{expanded.last_error}</div>
          ) : null}
          {/* The explicit expand is the envelope-visibility gate. Thin payload: ids only. */}
          <pre className="overflow-x-auto rounded bg-elevated p-2 text-xs">
            {JSON.stringify(expanded.envelope, null, 2)}
          </pre>
        </Card>
      ) : null}
    </div>
  );
}
