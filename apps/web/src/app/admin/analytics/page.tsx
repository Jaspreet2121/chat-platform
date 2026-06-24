"use client";

import { ComponentType, useEffect, useState } from "react";
import {
  Activity,
  AlertCircle,
  HardDrive,
  Loader2,
  MessageSquare,
  MessagesSquare,
  Users
} from "lucide-react";
import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  CartesianGrid,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis
} from "recharts";
import {
  AnalyticsOverview,
  AnalyticsTimeseries,
  getAdminAnalyticsOverview,
  getAdminAnalyticsTimeseries
} from "@/lib/api";
import { Card } from "@/components";

function formatBytes(bytes: number): string {
  if (!bytes) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  const i = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  return `${(bytes / Math.pow(1024, i)).toFixed(i === 0 ? 0 : 1)} ${units[i]}`;
}

function formatNumber(n: number): string {
  return n.toLocaleString();
}

function StatCard({
  label,
  value,
  icon: Icon
}: {
  label: string;
  value: string;
  icon: ComponentType<{ className?: string }>;
}) {
  return (
    <Card className="p-4">
      <div className="flex items-center gap-3">
        <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-elevated text-brand-hover">
          <Icon className="h-5 w-5" />
        </div>
        <div className="min-w-0">
          <p className="truncate text-xs font-medium uppercase tracking-wide text-faint">{label}</p>
          <p className="text-xl font-semibold text-fg">{value}</p>
        </div>
      </div>
    </Card>
  );
}

const axisProps = {
  stroke: "#5b6472",
  tick: { fill: "#9aa3b2", fontSize: 11 },
  tickLine: false,
  axisLine: false
};

const tooltipStyle = {
  contentStyle: {
    background: "#12151c",
    border: "1px solid #262b36",
    borderRadius: "0.625rem",
    color: "#e7e9ee",
    fontSize: 12
  },
  labelStyle: { color: "#9aa3b2" },
  cursor: { stroke: "#333a47" }
};

function shortDate(date: string): string {
  // "2026-06-25" -> "06-25"
  return date.length >= 10 ? date.slice(5) : date;
}

function ChartCard({
  title,
  children
}: {
  title: string;
  children: React.ReactElement;
}) {
  return (
    <Card className="p-5">
      <p className="mb-4 text-sm font-medium text-fg">{title}</p>
      <div className="h-56 w-full">
        <ResponsiveContainer width="100%" height="100%">
          {children}
        </ResponsiveContainer>
      </div>
    </Card>
  );
}

export default function AdminAnalyticsPage() {
  const [overview, setOverview] = useState<AnalyticsOverview | null>(null);
  const [series, setSeries] = useState<AnalyticsTimeseries | null>(null);
  const [error, setError] = useState("");
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    let active = true;
    async function load() {
      try {
        const [o, s] = await Promise.all([
          getAdminAnalyticsOverview(),
          getAdminAnalyticsTimeseries(30)
        ]);
        if (!active) return;
        setOverview(o);
        setSeries(s);
      } catch (caught) {
        if (active) setError(caught instanceof Error ? caught.message : "Failed to load analytics.");
      } finally {
        if (active) setIsLoading(false);
      }
    }
    void load();
    return () => {
      active = false;
    };
  }, []);

  if (isLoading) {
    return (
      <div className="flex h-64 items-center justify-center text-muted">
        <Loader2 className="mr-2 h-5 w-5 animate-spin" /> Loading analytics…
      </div>
    );
  }

  if (error || !overview || !series) {
    return (
      <Card className="mx-auto max-w-md p-8 text-center">
        <AlertCircle className="mx-auto mb-3 h-8 w-8 text-danger" />
        <p className="text-sm font-medium text-fg">Couldn&apos;t load analytics</p>
        <p className="mt-1 text-sm text-muted">{error || "No data available."}</p>
      </Card>
    );
  }

  const cards = [
    { label: "Users", value: formatNumber(overview.totals.users), icon: Users },
    { label: "Messages", value: formatNumber(overview.totals.messages), icon: MessageSquare },
    {
      label: "Conversations",
      value: formatNumber(overview.totals.conversations),
      icon: MessagesSquare
    },
    { label: "Storage", value: formatBytes(overview.totals.storage_bytes), icon: HardDrive },
    {
      label: "Active (7d)",
      value: formatNumber(overview.activity.active_conversations_7d),
      icon: Activity
    },
    { label: "Messages (24h)", value: formatNumber(overview.activity.messages_24h), icon: MessageSquare }
  ];

  return (
    <div className="mx-auto max-w-5xl animate-fade-in space-y-8">
      <div>
        <h2 className="text-xl font-semibold text-fg">Analytics</h2>
        <p className="text-sm text-muted">
          Read-only overview of users, conversations, and messages — last 30 days.
        </p>
      </div>

      <section className="grid grid-cols-2 gap-3 lg:grid-cols-3">
        {cards.map((c) => (
          <StatCard key={c.label} label={c.label} value={c.value} icon={c.icon} />
        ))}
      </section>

      <section className="grid gap-4 lg:grid-cols-2">
        <ChartCard title="Messages per day">
          <AreaChart data={series.messages} margin={{ top: 4, right: 8, left: -16, bottom: 0 }}>
            <defs>
              <linearGradient id="msgFill" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stopColor="#6366f1" stopOpacity={0.4} />
                <stop offset="100%" stopColor="#6366f1" stopOpacity={0} />
              </linearGradient>
            </defs>
            <CartesianGrid stroke="#262b36" vertical={false} />
            <XAxis dataKey="date" tickFormatter={shortDate} {...axisProps} minTickGap={24} />
            <YAxis allowDecimals={false} width={32} {...axisProps} />
            <Tooltip {...tooltipStyle} />
            <Area
              type="monotone"
              dataKey="count"
              name="messages"
              stroke="#818cf8"
              strokeWidth={2}
              fill="url(#msgFill)"
            />
          </AreaChart>
        </ChartCard>

        <ChartCard title="Signups per day">
          <BarChart data={series.signups} margin={{ top: 4, right: 8, left: -16, bottom: 0 }}>
            <CartesianGrid stroke="#262b36" vertical={false} />
            <XAxis dataKey="date" tickFormatter={shortDate} {...axisProps} minTickGap={24} />
            <YAxis allowDecimals={false} width={32} {...axisProps} />
            <Tooltip {...tooltipStyle} />
            <Bar dataKey="count" name="signups" fill="#22c55e" radius={[3, 3, 0, 0]} />
          </BarChart>
        </ChartCard>

        <ChartCard title="New conversations per day">
          <LineChart data={series.conversations} margin={{ top: 4, right: 8, left: -16, bottom: 0 }}>
            <CartesianGrid stroke="#262b36" vertical={false} />
            <XAxis dataKey="date" tickFormatter={shortDate} {...axisProps} minTickGap={24} />
            <YAxis allowDecimals={false} width={32} {...axisProps} />
            <Tooltip {...tooltipStyle} />
            <Line
              type="monotone"
              dataKey="count"
              name="conversations"
              stroke="#38bdf8"
              strokeWidth={2}
              dot={false}
            />
          </LineChart>
        </ChartCard>

        <Card className="p-5">
          <p className="mb-4 text-sm font-medium text-fg">Auth (last 7 days)</p>
          <div className="space-y-3">
            <div className="flex items-center justify-between">
              <span className="text-sm text-muted">Successful logins</span>
              <span className="font-semibold text-success">
                {formatNumber(overview.auth.login_success_7d)}
              </span>
            </div>
            <div className="flex items-center justify-between">
              <span className="text-sm text-muted">Failed logins</span>
              <span className="font-semibold text-danger">
                {formatNumber(overview.auth.login_failure_7d)}
              </span>
            </div>
            <div className="flex items-center justify-between border-t border-border pt-3">
              <span className="text-sm text-muted">Messages (7d)</span>
              <span className="font-semibold text-fg">
                {formatNumber(overview.activity.messages_7d)}
              </span>
            </div>
          </div>
        </Card>
      </section>
    </div>
  );
}
