"use client";

import { useCallback, useEffect, useState } from "react";
import { Boxes, Loader2, RefreshCw, Search } from "lucide-react";
import { AdminApp, getAdminApps } from "@/lib/api";
import { Button, Card, Input } from "@/components";
import { cn } from "@/lib/cn";

// Cross-tenant apps overview (Surface 3): every registered live app with its owner, usage, and key/webhook
// aggregates. Read-only — the base billing will later consume. Backend never sends secrets; nothing here
// could render one.

function formatBytes(bytes: number): string {
  if (bytes >= 1024 ** 3) return `${(bytes / 1024 ** 3).toFixed(1)} GB`;
  if (bytes >= 1024 ** 2) return `${(bytes / 1024 ** 2).toFixed(1)} MB`;
  if (bytes >= 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${bytes} B`;
}

function formatCount(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`;
  return String(n);
}

function formatDate(iso?: string | null): string {
  if (!iso) return "—";
  const parsed = new Date(iso);
  return Number.isNaN(parsed.getTime()) ? "—" : parsed.toLocaleDateString();
}

export default function AdminAppsPage() {
  const [apps, setApps] = useState<AdminApp[]>([]);
  const [q, setQ] = useState("");
  const [error, setError] = useState("");
  const [isLoading, setIsLoading] = useState(true);
  const [isRefreshing, setIsRefreshing] = useState(false);

  const load = useCallback(async (query: string, refresh = false) => {
    if (refresh) setIsRefreshing(true);
    try {
      const result = await getAdminApps(query);
      setApps(result.apps);
      setError("");
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Failed to load apps.");
    } finally {
      setIsLoading(false);
      setIsRefreshing(false);
    }
  }, []);

  useEffect(() => {
    void load("");
  }, [load]);

  // Debounced search — the backend filters by name or id.
  useEffect(() => {
    const timer = setTimeout(() => void load(q), 300);
    return () => clearTimeout(timer);
  }, [q, load]);

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold text-fg">Apps</h1>
          <p className="mt-0.5 text-sm text-muted">
            Every registered app across the platform — owner, usage, keys, webhooks.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <div className="relative">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-faint" />
            <Input
              value={q}
              onChange={(event) => setQ(event.target.value)}
              placeholder="Search name or id…"
              className="w-64 pl-9"
            />
          </div>
          <Button variant="ghost" onClick={() => void load(q, true)} disabled={isRefreshing}>
            {isRefreshing ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />}
            Refresh
          </Button>
        </div>
      </div>

      {error ? (
        <Card className="border-danger/40 bg-danger/5 p-4 text-sm text-danger">{error}</Card>
      ) : null}

      {isLoading ? (
        <Card className="flex items-center justify-center gap-2 p-10 text-sm text-muted">
          <Loader2 className="h-4 w-4 animate-spin" /> Loading apps…
        </Card>
      ) : apps.length === 0 ? (
        <Card className="flex flex-col items-center gap-2 p-10 text-center">
          <Boxes className="h-8 w-8 text-faint" />
          <p className="text-sm font-medium text-fg">No apps found</p>
          <p className="text-xs text-muted">
            {q ? "Nothing matches this search." : "No apps are registered yet."}
          </p>
        </Card>
      ) : (
        <Card className="overflow-x-auto p-0">
          <table className="w-full min-w-[880px] text-sm">
            <thead>
              <tr className="border-b border-border text-left text-xs uppercase tracking-wide text-faint">
                <th className="px-4 py-3 font-medium">App</th>
                <th className="px-4 py-3 font-medium">Owner</th>
                <th className="px-4 py-3 font-medium">Created</th>
                <th className="px-4 py-3 text-right font-medium">Users</th>
                <th className="px-4 py-3 text-right font-medium">Convos</th>
                <th className="px-4 py-3 text-right font-medium">Messages</th>
                <th className="px-4 py-3 text-right font-medium">Storage</th>
                <th className="px-4 py-3 text-right font-medium">Keys</th>
                <th className="px-4 py-3 text-right font-medium">Webhooks</th>
              </tr>
            </thead>
            <tbody>
              {apps.map((app) => (
                <tr key={app.app_id} className="border-b border-border/60 last:border-0">
                  <td className="px-4 py-3">
                    <div className="flex items-center gap-2">
                      <span className="font-medium text-fg">{app.name}</span>
                      {app.test_twin ? (
                        <span className="rounded-full border border-amber-500/40 bg-amber-500/10 px-1.5 py-0.5 text-[10px] font-medium text-amber-400">
                          test twin
                        </span>
                      ) : null}
                    </div>
                    <p className="mt-0.5 font-mono text-[11px] text-faint">{app.app_id}</p>
                  </td>
                  <td className="px-4 py-3">
                    {app.owner ? (
                      <span className="text-fg" title={app.owner.user_id}>
                        {app.owner.display}
                      </span>
                    ) : (
                      <span className="text-faint">—</span>
                    )}
                  </td>
                  <td className="px-4 py-3 text-muted">{formatDate(app.created_at)}</td>
                  <td className="px-4 py-3 text-right tabular-nums text-fg">{formatCount(app.counts.users)}</td>
                  <td className="px-4 py-3 text-right tabular-nums text-fg">
                    {formatCount(app.counts.conversations)}
                  </td>
                  <td className="px-4 py-3 text-right tabular-nums text-fg">
                    {formatCount(app.counts.messages)}
                  </td>
                  <td className="px-4 py-3 text-right tabular-nums text-muted">
                    {formatBytes(app.counts.storage_bytes)}
                  </td>
                  <td className="px-4 py-3 text-right">
                    <span className="tabular-nums text-fg">{app.api_keys.live}</span>
                    <span className="text-faint"> live · </span>
                    <span className="tabular-nums text-fg">{app.api_keys.test}</span>
                    <span className="text-faint"> test</span>
                    {app.api_keys.revoked > 0 ? (
                      <span
                        className={cn("ml-1 text-[11px] text-faint")}
                        title={`${app.api_keys.revoked} revoked`}
                      >
                        (+{app.api_keys.revoked} revoked)
                      </span>
                    ) : null}
                  </td>
                  <td className="px-4 py-3 text-right">
                    <span className="tabular-nums text-fg">{app.webhooks.enabled}</span>
                    <span className="text-faint">/{app.webhooks.total} enabled</span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </Card>
      )}
    </div>
  );
}
