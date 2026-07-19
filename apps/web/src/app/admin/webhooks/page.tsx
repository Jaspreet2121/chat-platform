"use client";

import { useCallback, useEffect, useState } from "react";
import { Loader2, RefreshCw, RotateCcw, Webhook } from "lucide-react";
import {
  FailedWebhook,
  getAdminFailedWebhooks,
  getCurrentSession,
  reenqueueWebhook,
  reenqueueWebhooksBulk
} from "@/lib/api";
import { Button, Card, Input } from "@/components";

// Webhook dead-letter ops (Surface 3): the failed-delivery queue with idempotent re-enqueue. The list is
// webhooks.view (root/admin/support); the mutations are webhooks.manage (root/admin) — the backend enforces,
// and we hide the buttons for viewers without the permission. The API never returns the event PAYLOAD
// (message content) and this page could not render one.

function formatTime(iso?: string | null): string {
  if (!iso) return "—";
  const parsed = new Date(iso);
  return Number.isNaN(parsed.getTime()) ? "—" : parsed.toLocaleString();
}

export default function AdminWebhooksPage() {
  const [rows, setRows] = useState<FailedWebhook[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [appId, setAppId] = useState("");
  const [eventType, setEventType] = useState("");
  const [canManage, setCanManage] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [isLoading, setIsLoading] = useState(true);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [isBulkBusy, setIsBulkBusy] = useState(false);

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
        const page = await getAdminFailedWebhooks({
          appId: appId.trim() || undefined,
          eventType: eventType.trim() || undefined,
          cursor: opts.cursor,
          limit: 50
        });
        setRows((prev) => (opts.append ? [...prev, ...page.data] : page.data));
        setCursor(page.next_cursor ?? null);
        setError("");
      } catch (caught) {
        setError(caught instanceof Error ? caught.message : "Failed to load failed deliveries.");
      } finally {
        setIsLoading(false);
        setIsLoadingMore(false);
      }
    },
    [appId, eventType]
  );

  useEffect(() => {
    const timer = setTimeout(() => void load(), 300);
    return () => clearTimeout(timer);
    // load() itself changes identity when the filters change — that's the debounce trigger.
  }, [load]);

  const onReenqueue = async (row: FailedWebhook) => {
    setBusyId(row.id);
    setNotice("");
    try {
      await reenqueueWebhook(row.id);
      // Optimistic removal: the row left the failed queue (a "noop" conflict means someone else already did —
      // removing it is right either way).
      setRows((prev) => prev.filter((r) => r.id !== row.id));
      setNotice("Delivery re-enqueued.");
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Re-enqueue failed.");
    } finally {
      setBusyId(null);
    }
  };

  const onBulk = async () => {
    const scope = [appId.trim() && `app ${appId.trim()}`, eventType.trim() && `type ${eventType.trim()}`]
      .filter(Boolean)
      .join(", ");
    const confirmed = window.confirm(
      `Re-enqueue ALL failed deliveries${scope ? ` matching ${scope}` : ""}? This retries every matching row.`
    );
    if (!confirmed) return;

    setIsBulkBusy(true);
    setNotice("");
    try {
      const result = await reenqueueWebhooksBulk({
        appId: appId.trim() || undefined,
        eventType: eventType.trim() || undefined
      });
      const n = result.reenqueued ?? result.count ?? 0;
      setNotice(`Re-enqueued ${n} deliveries.`);
      await load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Bulk re-enqueue failed.");
    } finally {
      setIsBulkBusy(false);
    }
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold text-fg">Webhooks</h1>
          <p className="mt-0.5 text-sm text-muted">
            Failed deliveries (dead-letter queue). Re-enqueue retries with backoff reset.
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Input
            value={appId}
            onChange={(event) => setAppId(event.target.value)}
            placeholder="Filter: app id"
            className="w-44 font-mono text-xs"
          />
          <Input
            value={eventType}
            onChange={(event) => setEventType(event.target.value)}
            placeholder="Filter: event type"
            className="w-44 text-xs"
          />
          <Button variant="ghost" onClick={() => void load()} disabled={isLoading}>
            {isLoading ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />}
            Refresh
          </Button>
          {canManage ? (
            <Button onClick={() => void onBulk()} disabled={isBulkBusy || rows.length === 0}>
              {isBulkBusy ? <Loader2 className="h-4 w-4 animate-spin" /> : <RotateCcw className="h-4 w-4" />}
              Re-enqueue all matching
            </Button>
          ) : null}
        </div>
      </div>

      {error ? <Card className="border-danger/40 bg-danger/5 p-4 text-sm text-danger">{error}</Card> : null}
      {notice ? <Card className="border-success/40 bg-success/5 p-4 text-sm text-success">{notice}</Card> : null}

      {isLoading ? (
        <Card className="flex items-center justify-center gap-2 p-10 text-sm text-muted">
          <Loader2 className="h-4 w-4 animate-spin" /> Loading failed deliveries…
        </Card>
      ) : rows.length === 0 ? (
        <Card className="flex flex-col items-center gap-2 p-10 text-center">
          <Webhook className="h-8 w-8 text-faint" />
          <p className="text-sm font-medium text-fg">No failed deliveries</p>
          <p className="text-xs text-muted">The dead-letter queue is empty for this filter.</p>
        </Card>
      ) : (
        <>
          <Card className="overflow-x-auto p-0">
            <table className="w-full min-w-[880px] text-sm">
              <thead>
                <tr className="border-b border-border text-left text-xs uppercase tracking-wide text-faint">
                  <th className="px-4 py-3 font-medium">Event</th>
                  <th className="px-4 py-3 font-medium">App</th>
                  <th className="px-4 py-3 font-medium">Endpoint</th>
                  <th className="px-4 py-3 text-right font-medium">Attempts</th>
                  <th className="px-4 py-3 font-medium">Last error</th>
                  <th className="px-4 py-3 font-medium">Created</th>
                  {canManage ? <th className="px-4 py-3" /> : null}
                </tr>
              </thead>
              <tbody>
                {rows.map((row) => (
                  <tr key={row.id} className="border-b border-border/60 last:border-0">
                    <td className="px-4 py-3">
                      <span className="font-medium text-fg">{row.event_type}</span>
                      <p className="mt-0.5 font-mono text-[11px] text-faint">{row.event_id}</p>
                    </td>
                    <td className="px-4 py-3">
                      <span className="font-mono text-[11px] text-muted">{row.app_id}</span>
                    </td>
                    <td className="max-w-[220px] px-4 py-3">
                      <span className="block truncate text-muted" title={row.endpoint_url ?? undefined}>
                        {row.endpoint_url ?? "—"}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-right tabular-nums text-fg">{row.attempts}</td>
                    <td className="max-w-[260px] px-4 py-3">
                      <span className="block truncate text-danger" title={row.last_error ?? undefined}>
                        {row.last_error ?? "—"}
                      </span>
                    </td>
                    <td className="whitespace-nowrap px-4 py-3 text-muted">{formatTime(row.created_at)}</td>
                    {canManage ? (
                      <td className="px-4 py-3 text-right">
                        <Button
                          variant="ghost"
                          onClick={() => void onReenqueue(row)}
                          disabled={busyId === row.id}
                        >
                          {busyId === row.id ? (
                            <Loader2 className="h-3.5 w-3.5 animate-spin" />
                          ) : (
                            <RotateCcw className="h-3.5 w-3.5" />
                          )}
                          Re-enqueue
                        </Button>
                      </td>
                    ) : null}
                  </tr>
                ))}
              </tbody>
            </table>
          </Card>

          {cursor ? (
            <div className="flex justify-center">
              <Button
                variant="ghost"
                onClick={() => void load({ append: true, cursor })}
                disabled={isLoadingMore}
              >
                {isLoadingMore ? <Loader2 className="h-4 w-4 animate-spin" /> : null}
                Load more
              </Button>
            </div>
          ) : null}
        </>
      )}
    </div>
  );
}
