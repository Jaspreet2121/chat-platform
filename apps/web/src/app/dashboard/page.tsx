"use client";

import { useCallback, useEffect, useState } from "react";
import { AppWindow, Loader2, Plus } from "lucide-react";
import { IntegratorApp, createApp, listApps } from "@/lib/api";
import { cn } from "@/lib/cn";
import { KeysPanel } from "./KeysPanel";
import { WebhooksPanel } from "./WebhooksPanel";

export default function DashboardPage() {
  const [apps, setApps] = useState<IntegratorApp[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [name, setName] = useState("");
  const [creating, setCreating] = useState(false);

  const refresh = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const list = await listApps();
      setApps(list);
      // Keep the current selection if it still exists; otherwise default to the first app.
      setSelectedId((cur) => (cur !== null && list.some((a) => a.app_id === cur) ? cur : list[0]?.app_id ?? null));
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load apps");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  async function create() {
    const n = name.trim();
    if (n === "" || creating) return;
    setCreating(true);
    setError("");
    try {
      const app = await createApp(n);
      setName("");
      await refresh();
      setSelectedId(app.app_id);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to create app");
    } finally {
      setCreating(false);
    }
  }

  const selected = apps.find((a) => a.app_id === selectedId) ?? null;

  return (
    <div className="mx-auto grid max-w-6xl gap-6 lg:grid-cols-[260px_minmax(0,1fr)]">
      {/* Apps sidebar */}
      <aside className="rounded-xl border border-border bg-surface p-4">
        <div className="mb-3 flex items-center gap-2">
          <AppWindow className="h-4 w-4 text-brand" aria-hidden />
          <h2 className="text-sm font-semibold text-fg">Apps</h2>
        </div>

        <div className="mb-3 flex items-center gap-2">
          <input
            value={name}
            placeholder="New app name"
            onChange={(e) => setName(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && void create()}
            className="h-9 min-w-0 flex-1 rounded-lg border border-border bg-elevated px-3 text-sm text-fg"
          />
          <button
            type="button"
            onClick={() => void create()}
            disabled={creating || name.trim() === ""}
            aria-label="Create app"
            className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-brand text-white transition-colors hover:bg-brand-hover disabled:opacity-50"
          >
            {creating ? <Loader2 className="h-4 w-4 animate-spin" aria-hidden /> : <Plus className="h-4 w-4" aria-hidden />}
          </button>
        </div>

        {error !== "" && <p className="mb-2 text-xs text-danger">{error}</p>}

        {loading ? (
          <p className="text-xs text-muted">Loading…</p>
        ) : apps.length === 0 ? (
          <p className="text-xs text-muted">No apps yet. Create one to get an app_id + keys.</p>
        ) : (
          <ul className="space-y-1">
            {apps.map((app) => (
              <li key={app.app_id}>
                <button
                  type="button"
                  onClick={() => setSelectedId(app.app_id)}
                  className={cn(
                    "w-full rounded-lg px-3 py-2 text-left transition-colors",
                    app.app_id === selectedId ? "bg-brand-subtle/60 ring-1 ring-brand/40" : "hover:bg-elevated"
                  )}
                >
                  <span className="block truncate text-sm font-medium text-fg">{app.name}</span>
                  <span className="block truncate font-mono text-[11px] text-muted">{app.app_id}</span>
                </button>
              </li>
            ))}
          </ul>
        )}
      </aside>

      {/* Selected app → keys + webhooks (both scoped to app.app_id) */}
      <div className="min-w-0">
        {selected !== null ? (
          <>
            <div className="mb-4">
              <h1 className="text-lg font-semibold text-fg">{selected.name}</h1>
              <p className="font-mono text-xs text-muted">
                {selected.app_id}
                {selected.mode ? ` · ${selected.mode}` : ""}
              </p>
            </div>
            {/* `key` forces a fresh fetch when the selected app changes. */}
            <KeysPanel key={`keys-${selected.app_id}`} app={selected} />
            <WebhooksPanel key={`hooks-${selected.app_id}`} app={selected} />
          </>
        ) : (
          <div className="flex h-full min-h-[200px] items-center justify-center rounded-xl border border-dashed border-border text-sm text-muted">
            {loading ? "Loading…" : "Create or select an app to manage its keys and webhooks."}
          </div>
        )}
      </div>
    </div>
  );
}
