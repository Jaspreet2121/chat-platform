// Pure shaping for the admin dashboard. Everything the dashboard DECIDES lives here rather than in
// JSX, because a wrong number on a dashboard is worse than no number: nobody re-derives it. Keeping
// the derivation testable is the only way "healthy" stays honest.

import type { AnalyticsOverview, DailyPoint, SystemHealth } from "@/lib/api";

export type HealthStrip = {
  // The dependencies that are NOT up, named. An empty list is the only good answer.
  depsDown: string[];
  // Every distinct build on the fleet. One entry = everything is on the same code. More than one
  // mid-deploy is expected; more than one an hour later is the bug you were looking for.
  shas: string[];
  shaState: "uniform" | "mixed" | "unknown";
  // Services reporting a build we could not read at all (down, or an image from before git_sha).
  shaUnknown: string[];
  lagStatus: string;
  // Groups actually behind or stalled — an "off" group is a decision, not an incident, so it is
  // never surfaced as a problem here.
  lagProblems: string[];
};

const UNKNOWN_SHA = "unknown";

export function buildHealthStrip(health: SystemHealth | null | undefined): HealthStrip {
  if (!health) {
    return {
      depsDown: [],
      shas: [],
      shaState: "unknown",
      shaUnknown: [],
      lagStatus: "unknown",
      lagProblems: []
    };
  }

  const deps = health.dependencies ?? ({} as SystemHealth["dependencies"]);
  const depsDown = Object.entries(deps)
    .filter(([, dep]) => dep?.status !== "up")
    .map(([name]) => name)
    .sort();

  const services = Array.isArray(health.services) ? health.services : [];
  const shaUnknown: string[] = [];
  const shas: string[] = [];
  for (const service of services) {
    const sha = typeof service.git_sha === "string" ? service.git_sha.trim() : "";
    if (!sha || sha === UNKNOWN_SHA) {
      shaUnknown.push(service.name);
      continue;
    }
    if (!shas.includes(sha)) shas.push(sha);
  }

  // "unknown" only when we read NO build at all. One readable build plus one unreadable is still a
  // fleet we know something about, and calling that "unknown" would hide the part we do know.
  const shaState = shas.length === 0 ? "unknown" : shas.length === 1 ? "uniform" : "mixed";

  const lag = health.consumer_lag;
  const groups = Array.isArray(lag?.groups) ? lag.groups : [];
  const lagProblems = groups
    .filter((g) => g.status === "behind" || g.status === "stalled")
    .map((g) => g.group_id);

  return {
    depsDown,
    shas,
    shaState,
    shaUnknown,
    lagStatus: typeof lag?.status === "string" ? lag.status : "unknown",
    lagProblems
  };
}

// True only when there is nothing to look at: no dependency down, one build everywhere, no lag.
export function healthStripIsClean(strip: HealthStrip): boolean {
  return (
    strip.depsDown.length === 0 &&
    strip.shaState === "uniform" &&
    strip.lagProblems.length === 0 &&
    strip.lagStatus === "ok"
  );
}

export type Sparkline = { path: string; max: number; total: number };

// An SVG polyline over a day series, scaled to the box. A flat series draws a flat line at the
// BOTTOM rather than dividing by zero — a month of no sign-ups is a real answer, not a broken chart.
export function sparkline(points: DailyPoint[], width = 240, height = 40): Sparkline {
  const counts = (points ?? []).map((p) => (Number.isFinite(p?.count) ? p.count : 0));
  const total = counts.reduce((a, b) => a + b, 0);
  const max = counts.reduce((a, b) => Math.max(a, b), 0);

  if (counts.length === 0) return { path: "", max: 0, total: 0 };
  if (counts.length === 1) return { path: `M 0 ${height} L ${width} ${height}`, max, total };

  const stepX = width / (counts.length - 1);
  const scaleY = max === 0 ? 0 : height / max;

  const path = counts
    .map((count, i) => {
      const x = (i * stepX).toFixed(2);
      const y = (height - count * scaleY).toFixed(2);
      return `${i === 0 ? "M" : "L"} ${x} ${y}`;
    })
    .join(" ");

  return { path, max, total };
}

export type UserMix = { real: number; v1: number; total: number; realPercent: number };

// Real vs v1 side by side. The percentage is of the TOTAL, and 0/0 is 0% rather than NaN.
export function userMix(overview: AnalyticsOverview | null | undefined): UserMix {
  const real = overview?.users?.real ?? 0;
  const v1 = overview?.users?.v1 ?? 0;
  const total = real + v1;
  return { real, v1, total, realPercent: total === 0 ? 0 : Math.round((real / total) * 100) };
}

export type PlatformCount = { platform: string; count: number };

// Sessions by platform, every platform present, biggest first, with "total" pulled out. A platform
// nobody is signed in on must render as 0 — a missing row reads as "no data" when it means "nobody".
export function sessionsByPlatform(overview: AnalyticsOverview | null | undefined): {
  total: number;
  platforms: PlatformCount[];
} {
  const sessions = overview?.sessions ?? {};
  const platforms = Object.entries(sessions)
    .filter(([name]) => name !== "total")
    .map(([platform, count]) => ({ platform, count: Number(count) || 0 }))
    .sort((a, b) => b.count - a.count || a.platform.localeCompare(b.platform));

  const total = Number(sessions.total ?? platforms.reduce((sum, p) => sum + p.count, 0)) || 0;
  return { total, platforms };
}
