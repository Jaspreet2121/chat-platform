"use client";

import { ComponentType, useEffect, useState } from "react";
import Link from "next/link";
import {
  Activity,
  AlertTriangle,
  CheckCircle2,
  Flag,
  Heart,
  Loader2,
  MapPin,
  MessageSquare,
  Smartphone,
  Sparkles,
  UserPlus,
  Users
} from "lucide-react";
import {
  AnalyticsOverview,
  AnalyticsTimeseries,
  SystemHealth,
  getAdminAnalyticsOverview,
  getAdminAnalyticsTimeseries,
  getAdminHealth
} from "@/lib/api";
import {
  buildHealthStrip,
  healthStripIsClean,
  sessionsByPlatform,
  sparkline,
  userMix
} from "@/lib/adminDashboard";
import { Card } from "@/components";
import { cn } from "@/lib/cn";

function n(value: number): string {
  return (value ?? 0).toLocaleString();
}

function Stat({
  label,
  value,
  hint,
  icon: Icon,
  href
}: {
  label: string;
  value: string;
  hint?: string;
  icon: ComponentType<{ className?: string }>;
  href?: string;
}) {
  const body = (
    <Card className={cn("h-full p-4", href && "transition-colors hover:border-border-strong")}>
      <div className="flex items-start gap-3">
        <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-elevated text-brand-hover">
          <Icon className="h-5 w-5" aria-hidden />
        </div>
        <div className="min-w-0">
          <p className="truncate text-xs font-medium uppercase tracking-wide text-faint">{label}</p>
          <p className="text-2xl font-semibold text-fg">{value}</p>
          {hint ? <p className="mt-0.5 text-xs text-muted">{hint}</p> : null}
        </div>
      </div>
    </Card>
  );
  return href ? <Link href={href}>{body}</Link> : body;
}

export default function AdminDashboardPage() {
  const [overview, setOverview] = useState<AnalyticsOverview | null>(null);
  const [series, setSeries] = useState<AnalyticsTimeseries | null>(null);
  const [health, setHealth] = useState<SystemHealth | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    // Health is fetched separately and allowed to fail on its own: it needs platform.view, which a
    // moderator does not have. A 403 there must not blank the numbers they ARE allowed to see.
    (async () => {
      try {
        const [o, t] = await Promise.all([
          getAdminAnalyticsOverview(),
          getAdminAnalyticsTimeseries(30)
        ]);
        if (cancelled) return;
        setOverview(o);
        setSeries(t);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : "Could not load the dashboard.");
      } finally {
        if (!cancelled) setLoading(false);
      }

      try {
        const h = await getAdminHealth();
        if (!cancelled) setHealth(h);
      } catch {
        // No permission, or the aggregator is down. The strip says "unavailable"; nothing else moves.
      }
    })();

    return () => {
      cancelled = true;
    };
  }, []);

  if (loading) {
    return (
      <div className="flex h-64 items-center justify-center text-muted">
        <Loader2 className="h-5 w-5 animate-spin" aria-hidden />
      </div>
    );
  }

  if (error) {
    return (
      <Card className="mx-auto max-w-2xl p-5">
        <div className="flex items-start gap-3">
          <AlertTriangle className="mt-0.5 h-5 w-5 shrink-0 text-danger" aria-hidden />
          <div>
            <p className="text-sm font-semibold text-fg">The dashboard could not load</p>
            <p className="mt-1 text-sm text-muted">{error}</p>
          </div>
        </div>
      </Card>
    );
  }

  const mix = userMix(overview);
  const sessions = sessionsByPlatform(overview);
  const signups = sparkline(series?.signups ?? [], 560, 56);
  const strip = buildHealthStrip(health);
  const clean = healthStripIsClean(strip);

  return (
    <div className="mx-auto max-w-6xl animate-fade-in space-y-6">
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Stat
          label="Real users"
          value={n(mix.real)}
          hint={`${mix.realPercent}% of ${n(mix.total)} · ${n(mix.v1)} from v1 apps`}
          icon={Users}
          href="/admin/moderation"
        />
        <Stat
          label="Active sessions"
          value={n(sessions.total)}
          hint={sessions.platforms.map((p) => `${p.platform} ${n(p.count)}`).join(" · ")}
          icon={Smartphone}
        />
        <Stat
          label="Messages today"
          value={n(overview?.messages_today ?? 0)}
          hint="From the search index"
          icon={MessageSquare}
        />
        <Stat
          label="Open reports"
          value={n(overview?.moderation?.reports_open ?? 0)}
          hint="Open or under review"
          icon={Flag}
          href="/admin/moderation"
        />
      </div>

      <Card className="p-5">
        <div className="mb-3 flex items-baseline justify-between gap-3">
          <div className="flex items-center gap-2">
            <UserPlus className="h-4 w-4 text-muted" aria-hidden />
            <p className="text-sm font-semibold text-fg">Sign-ups</p>
          </div>
          <p className="text-xs text-muted">
            {n(signups.total)} in 30 days · peak {n(signups.max)}/day
          </p>
        </div>
        {signups.path ? (
          <svg
            viewBox="0 0 560 56"
            preserveAspectRatio="none"
            className="h-14 w-full text-brand-hover"
            role="img"
            aria-label={`Sign-ups over the last 30 days: ${n(signups.total)} total`}
          >
            <path d={signups.path} fill="none" stroke="currentColor" strokeWidth="2" />
          </svg>
        ) : (
          <p className="text-sm text-muted">No sign-ups in the last 30 days.</p>
        )}
      </Card>

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Stat
          label="Matches today"
          value={n(overview?.dating?.matches_today ?? 0)}
          hint={`${n(overview?.dating?.matches_7d ?? 0)} in 7 days`}
          icon={Sparkles}
        />
        <Stat label="Likes today" value={n(overview?.dating?.likes_today ?? 0)} icon={Heart} />
        <Stat
          label="Nearby right now"
          value={n(overview?.nearby?.opted_in_now ?? 0)}
          // Said out loud on the page so nobody goes looking for the list: there isn't one.
          hint="Opted in · count only, no names or locations"
          icon={MapPin}
        />
        <Stat
          label="Conversations"
          value={n(overview?.totals?.conversations ?? 0)}
          hint={`${n(overview?.activity?.active_conversations_7d ?? 0)} active in 7 days`}
          icon={Activity}
          href="/admin/analytics"
        />
      </div>

      <Card className="p-5">
        <div className="mb-3 flex items-center justify-between gap-3">
          <div className="flex items-center gap-2">
            {clean ? (
              <CheckCircle2 className="h-4 w-4 text-success" aria-hidden />
            ) : (
              <AlertTriangle className="h-4 w-4 text-amber-400" aria-hidden />
            )}
            <p className="text-sm font-semibold text-fg">Platform health</p>
          </div>
          <Link href="/admin/health" className="text-xs text-brand-hover hover:underline">
            Details
          </Link>
        </div>

        {!health ? (
          <p className="text-sm text-muted">Health is unavailable for this session.</p>
        ) : (
          <dl className="grid gap-3 sm:grid-cols-3">
            <div>
              <dt className="text-xs uppercase tracking-wide text-faint">Dependencies</dt>
              <dd className="mt-0.5 text-sm text-fg">
                {strip.depsDown.length === 0 ? (
                  <span className="text-success">All up</span>
                ) : (
                  <span className="text-danger">{strip.depsDown.join(", ")} down</span>
                )}
              </dd>
            </div>
            <div>
              <dt className="text-xs uppercase tracking-wide text-faint">Build</dt>
              <dd className="mt-0.5 text-sm text-fg">
                {strip.shaState === "uniform" ? (
                  <span className="font-mono text-xs">{strip.shas[0]}</span>
                ) : strip.shaState === "mixed" ? (
                  <span className="text-amber-400">
                    {strip.shas.length} builds live — mid-deploy?
                  </span>
                ) : (
                  <span className="text-muted">Unknown</span>
                )}
                {strip.shaUnknown.length > 0 ? (
                  <span className="ml-1 text-xs text-faint">
                    ({strip.shaUnknown.join(", ")} unreadable)
                  </span>
                ) : null}
              </dd>
            </div>
            <div>
              <dt className="text-xs uppercase tracking-wide text-faint">Consumer lag</dt>
              <dd className="mt-0.5 text-sm text-fg">
                {strip.lagProblems.length === 0 ? (
                  <span className={strip.lagStatus === "ok" ? "text-success" : "text-muted"}>
                    {strip.lagStatus}
                  </span>
                ) : (
                  <span className="text-amber-400">{strip.lagProblems.join(", ")}</span>
                )}
              </dd>
            </div>
          </dl>
        )}
      </Card>
    </div>
  );
}
