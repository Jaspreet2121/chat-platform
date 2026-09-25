import { describe, expect, it } from "vitest";
import {
  buildHealthStrip,
  healthStripIsClean,
  sessionsByPlatform,
  sparkline,
  userMix
} from "@/lib/adminDashboard";
import type { AnalyticsOverview, SystemHealth } from "@/lib/api";

function health(overrides: Partial<SystemHealth> = {}): SystemHealth {
  return {
    status: "healthy",
    checked_at: "2026-09-25T00:00:00Z",
    dependencies: {
      postgres: { status: "up" },
      kafka: { status: "up" },
      minio: { status: "up" }
    },
    services: [
      { name: "auth", status: "up", git_sha: "aaa" },
      { name: "user", status: "up", git_sha: "aaa" }
    ],
    consumer_lag: { status: "ok", groups: [] },
    ...overrides
  };
}

describe("buildHealthStrip", () => {
  it("names the dependencies that are not up", () => {
    const strip = buildHealthStrip(
      health({
        dependencies: {
          postgres: { status: "up" },
          kafka: { status: "down" },
          minio: { status: "unknown" }
        }
      })
    );
    expect(strip.depsDown).toEqual(["kafka", "minio"]);
  });

  it("reports one build as uniform and two as mixed", () => {
    expect(buildHealthStrip(health()).shaState).toBe("uniform");
    const mixed = buildHealthStrip(
      health({
        services: [
          { name: "auth", status: "up", git_sha: "aaa" },
          { name: "user", status: "up", git_sha: "bbb" }
        ]
      })
    );
    expect(mixed.shaState).toBe("mixed");
    expect(mixed.shas).toEqual(["aaa", "bbb"]);
  });

  it("separates an unreadable build from a mixed fleet", () => {
    // A down service must not be counted as a SECOND build — that would report a mixed fleet every
    // time one container is restarting, and the alarm people ignore is the one that cries wolf.
    const strip = buildHealthStrip(
      health({
        services: [
          { name: "auth", status: "up", git_sha: "aaa" },
          { name: "notification", status: "unknown", git_sha: "unknown" },
          { name: "media", status: "down" }
        ]
      })
    );
    expect(strip.shaState).toBe("uniform");
    expect(strip.shaUnknown).toEqual(["notification", "media"]);
  });

  it("treats an 'off' consumer group as fine and 'behind'/'stalled' as problems", () => {
    const strip = buildHealthStrip(
      health({
        consumer_lag: {
          status: "behind",
          groups: [
            { group_id: "g-off", status: "off" },
            { group_id: "g-ok", status: "ok" },
            { group_id: "g-behind", status: "behind", lag: 900 },
            { group_id: "g-stalled", status: "stalled", lag: 3 }
          ]
        }
      })
    );
    expect(strip.lagProblems).toEqual(["g-behind", "g-stalled"]);
  });

  it("returns an all-unknown strip rather than throwing when health never loaded", () => {
    const strip = buildHealthStrip(null);
    expect(strip.shaState).toBe("unknown");
    expect(strip.lagStatus).toBe("unknown");
    expect(healthStripIsClean(strip)).toBe(false);
  });

  it("is clean only when nothing at all is wrong", () => {
    expect(healthStripIsClean(buildHealthStrip(health()))).toBe(true);
    expect(
      healthStripIsClean(
        buildHealthStrip(health({ consumer_lag: { status: "stale", groups: [] } }))
      )
    ).toBe(false);
  });
});

describe("sparkline", () => {
  it("scales the tallest day to the top of the box", () => {
    const { path, max, total } = sparkline(
      [
        { date: "a", count: 0 },
        { date: "b", count: 5 },
        { date: "c", count: 10 }
      ],
      100,
      40
    );
    expect(max).toBe(10);
    expect(total).toBe(15);
    expect(path).toBe("M 0.00 40.00 L 50.00 20.00 L 100.00 0.00");
  });

  it("draws a flat baseline for an all-zero month instead of dividing by zero", () => {
    const { path } = sparkline(
      [
        { date: "a", count: 0 },
        { date: "b", count: 0 }
      ],
      10,
      4
    );
    expect(path).toBe("M 0.00 4.00 L 10.00 4.00");
    expect(path).not.toContain("NaN");
  });

  it("returns an empty path for no data", () => {
    expect(sparkline([]).path).toBe("");
  });
});

describe("userMix", () => {
  it("keeps real and v1 apart and reports the real share", () => {
    const mix = userMix({ users: { real: 3, v1: 1 } } as AnalyticsOverview);
    expect(mix).toEqual({ real: 3, v1: 1, total: 4, realPercent: 75 });
  });

  it("is 0% rather than NaN with no users at all", () => {
    expect(userMix(null).realPercent).toBe(0);
  });
});

describe("sessionsByPlatform", () => {
  it("orders platforms by size and keeps the zero ones", () => {
    const { total, platforms } = sessionsByPlatform({
      sessions: { android: 2, ios: 7, web: 0, total: 9 }
    } as unknown as AnalyticsOverview);
    expect(total).toBe(9);
    expect(platforms).toEqual([
      { platform: "ios", count: 7 },
      { platform: "android", count: 2 },
      { platform: "web", count: 0 }
    ]);
  });

  it("falls back to summing the platforms when no total is sent", () => {
    const { total } = sessionsByPlatform({
      sessions: { android: 2, ios: 3 }
    } as unknown as AnalyticsOverview);
    expect(total).toBe(5);
  });
});
