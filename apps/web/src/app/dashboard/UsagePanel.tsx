"use client";

import { useCallback, useEffect, useState } from "react";
import { BarChart3 } from "lucide-react";
import { AppUsage, IntegratorApp, fetchUsage } from "@/lib/api";

// Every number here is a real count from the backend — nothing is estimated. Messages are counted via
// their parent conversation (a message's authoritative tenant), not the message row's own app_id.
export function UsagePanel({ app }: { app: IntegratorApp }) {
  const [usage, setUsage] = useState<AppUsage | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const refresh = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      setUsage(await fetchUsage(app.app_id));
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load usage");
    } finally {
      setLoading(false);
    }
  }, [app.app_id]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  return (
    <section className="mb-6 rounded-xl border border-border bg-surface p-5">
      <div className="mb-4 flex items-center gap-2">
        <BarChart3 className="h-4 w-4 text-brand" aria-hidden />
        <h3 className="text-sm font-semibold text-fg">Usage</h3>
      </div>

      {error !== "" ? (
        <p className="text-xs text-danger">{error}</p>
      ) : (
        <dl className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <Stat label="Users" value={usage?.users} loading={loading} />
          <Stat label="Conversations" value={usage?.conversations} loading={loading} />
          <Stat label="Messages" value={usage?.messages} loading={loading} />
          <Stat
            label="Storage"
            loading={loading}
            display={usage === undefined || usage === null ? undefined : formatBytes(usage.storage_bytes)}
          />
        </dl>
      )}
    </section>
  );
}

function Stat({
  label,
  value,
  display,
  loading
}: {
  label: string;
  value?: number;
  display?: string;
  loading: boolean;
}) {
  const shown = display ?? (typeof value === "number" ? value.toLocaleString() : undefined);
  return (
    <div className="rounded-lg border border-border/60 bg-elevated/40 px-3 py-2">
      <dt className="text-[11px] uppercase tracking-wide text-muted">{label}</dt>
      <dd className="mt-0.5 text-lg font-semibold tabular-nums text-fg">
        {loading ? <span className="text-sm text-muted">…</span> : (shown ?? "—")}
      </dd>
    </div>
  );
}

function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  const i = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  const value = bytes / Math.pow(1024, i);
  return `${value >= 10 || i === 0 ? Math.round(value) : value.toFixed(1)} ${units[i]}`;
}
