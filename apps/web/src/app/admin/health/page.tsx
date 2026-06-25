"use client";

import { ComponentType, useCallback, useEffect, useState } from "react";
import {
  Activity,
  AlertTriangle,
  Boxes,
  CheckCircle2,
  Database,
  HardDrive,
  Loader2,
  RefreshCw,
  Radio,
  Server,
  XCircle
} from "lucide-react";
import { DepHealth, SystemHealth, getAdminHealth } from "@/lib/api";
import { Button, Card } from "@/components";
import { cn } from "@/lib/cn";

function StatusDot({ status }: { status: string }) {
  const tone =
    status === "up" || status === "healthy"
      ? "bg-success"
      : status === "down" || status === "degraded"
        ? "bg-danger"
        : "bg-faint";
  return <span className={cn("inline-block h-2.5 w-2.5 rounded-full", tone)} />;
}

const overallTone: Record<string, { ring: string; text: string; icon: ComponentType<{ className?: string }> }> = {
  healthy: { ring: "border-success/40 bg-success/10", text: "text-success", icon: CheckCircle2 },
  degraded: { ring: "border-amber-500/40 bg-amber-500/10", text: "text-amber-400", icon: AlertTriangle },
  down: { ring: "border-danger/40 bg-danger/10", text: "text-danger", icon: XCircle }
};

function DependencyCard({
  label,
  icon: Icon,
  dep
}: {
  label: string;
  icon: ComponentType<{ className?: string }>;
  dep: DepHealth;
}) {
  const up = dep.status === "up";
  return (
    <Card className="p-4">
      <div className="flex items-center gap-3">
        <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-elevated text-muted">
          <Icon className="h-5 w-5" />
        </div>
        <div className="min-w-0 flex-1">
          <p className="text-sm font-medium text-fg">{label}</p>
          <div className="mt-0.5 flex items-center gap-1.5">
            <StatusDot status={dep.status} />
            <span className={cn("text-xs font-medium capitalize", up ? "text-success" : "text-danger")}>
              {dep.status}
            </span>
            {typeof dep.latency_ms === "number" ? (
              <span className="text-xs text-faint">· {dep.latency_ms} ms</span>
            ) : null}
          </div>
        </div>
      </div>
      {dep.error ? <p className="mt-2 truncate text-xs text-danger" title={dep.error}>{dep.error}</p> : null}
    </Card>
  );
}

const serviceIcons: Record<string, ComponentType<{ className?: string }>> = {
  auth: Server,
  user: Server,
  conversation: Server,
  message: Server,
  media: HardDrive,
  realtime: Radio,
  notification: Boxes
};

export default function AdminHealthPage() {
  const [health, setHealth] = useState<SystemHealth | null>(null);
  const [error, setError] = useState("");
  const [isLoading, setIsLoading] = useState(true);
  const [isRefreshing, setIsRefreshing] = useState(false);

  const load = useCallback(async (refresh = false) => {
    if (refresh) setIsRefreshing(true);
    try {
      const data = await getAdminHealth();
      setHealth(data);
      setError("");
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Failed to load health.");
    } finally {
      setIsLoading(false);
      setIsRefreshing(false);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  if (isLoading) {
    return (
      <div className="flex h-64 items-center justify-center text-muted">
        <Loader2 className="mr-2 h-5 w-5 animate-spin" /> Checking system health…
      </div>
    );
  }

  if (error || !health) {
    return (
      <Card className="mx-auto max-w-md p-8 text-center">
        <AlertTriangle className="mx-auto mb-3 h-8 w-8 text-danger" />
        <p className="text-sm font-medium text-fg">Couldn&apos;t load health</p>
        <p className="mt-1 text-sm text-muted">{error || "No data available."}</p>
      </Card>
    );
  }

  const tone = overallTone[health.status] ?? overallTone.down;
  const OverallIcon = tone.icon;
  const checked = new Date(health.checked_at);
  const checkedLabel = Number.isNaN(checked.getTime()) ? health.checked_at : checked.toLocaleTimeString();

  return (
    <div className="mx-auto max-w-5xl animate-fade-in space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-xl font-semibold text-fg">System Health</h2>
          <p className="text-sm text-muted">Last checked {checkedLabel}</p>
        </div>
        <Button
          variant="ghost"
          size="sm"
          className="border border-border"
          onClick={() => load(true)}
          isLoading={isRefreshing}
          leftIcon={<RefreshCw className="h-4 w-4" />}
        >
          Refresh
        </Button>
      </div>

      {/* Overall status banner */}
      <Card className={cn("flex items-center gap-3 border p-4", tone.ring)}>
        <OverallIcon className={cn("h-6 w-6", tone.text)} />
        <div>
          <p className={cn("text-sm font-semibold capitalize", tone.text)}>{health.status}</p>
          <p className="text-xs text-muted">
            {health.status === "healthy"
              ? "All dependencies and services are operational."
              : health.status === "degraded"
                ? "Some dependencies or services are degraded."
                : "Major outage — core dependencies are down."}
          </p>
        </div>
      </Card>

      {/* Dependencies */}
      <section>
        <h3 className="mb-2 text-xs font-medium uppercase tracking-wide text-faint">Dependencies</h3>
        <div className="grid gap-3 sm:grid-cols-3">
          <DependencyCard label="Postgres" icon={Database} dep={health.dependencies.postgres} />
          <DependencyCard label="Kafka" icon={Activity} dep={health.dependencies.kafka} />
          <DependencyCard label="MinIO" icon={HardDrive} dep={health.dependencies.minio} />
        </div>
      </section>

      {/* Services */}
      <section>
        <h3 className="mb-2 text-xs font-medium uppercase tracking-wide text-faint">Services</h3>
        <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
          {health.services.map((svc) => {
            const Icon = serviceIcons[svc.name] ?? Server;
            return (
              <Card key={svc.name} className="flex items-center gap-3 p-3">
                <Icon className="h-4 w-4 text-muted" />
                <span className="flex-1 text-sm font-medium capitalize text-fg">{svc.name}</span>
                <StatusDot status={svc.status} />
                <span
                  className={cn(
                    "text-xs font-medium capitalize",
                    svc.status === "up"
                      ? "text-success"
                      : svc.status === "down"
                        ? "text-danger"
                        : "text-faint"
                  )}
                >
                  {svc.status}
                </span>
              </Card>
            );
          })}
        </div>
      </section>
    </div>
  );
}
