import { describe, expect, it, vi } from "vitest";
import {
  createFreshnessGate,
  createSingleFlight,
  shouldRefreshAccessToken,
  type RefreshOutcome
} from "../refresh";
import { resolveAccessExpiry } from "../session";
import { socketParams } from "../realtime";

describe("socketParams — the socket reads the CURRENT token, not the one it was built with", () => {
  it("re-reads the token on every call", () => {
    let token: string | null = "first";
    const read = () => token;

    expect(socketParams(read)).toEqual({ authorization: "Bearer first" });

    // The rotation that used to be invisible to a socket built with a static params object.
    token = "second";
    expect(socketParams(read)).toEqual({ authorization: "Bearer second" });
  });

  it("sends no authorization at all when there is no token", () => {
    expect(socketParams(() => null)).toEqual({});
    expect(socketParams(() => "")).toEqual({});
  });
});

describe("shouldRefreshAccessToken", () => {
  const now = 1_000_000;

  it("is false while the token has comfortably longer than the leeway left", () => {
    expect(shouldRefreshAccessToken(now + 10 * 60_000, now)).toBe(false);
  });

  it("is true inside the leeway — the sync params callback cannot await, so refresh early", () => {
    expect(shouldRefreshAccessToken(now + 59_000, now)).toBe(true);
    expect(shouldRefreshAccessToken(now + 60_000, now)).toBe(true); // exactly at the boundary
  });

  it("is true for an already-expired token", () => {
    expect(shouldRefreshAccessToken(now - 1, now)).toBe(true);
  });

  it("is true when the expiry is UNKNOWN — one refresh teaches it", () => {
    // A session stored before the expiry was persisted. Assuming "fresh" here is what leaves the
    // socket presenting a token it cannot reason about.
    expect(shouldRefreshAccessToken(null, now)).toBe(true);
  });

  it("honours a custom leeway", () => {
    expect(shouldRefreshAccessToken(now + 90_000, now, 120_000)).toBe(true);
    expect(shouldRefreshAccessToken(now + 90_000, now, 30_000)).toBe(false);
  });
});

describe("createFreshnessGate", () => {
  const refreshed: RefreshOutcome = { status: "refreshed" };

  it("does NO network while the token is fresh", async () => {
    const refresh = vi.fn(async () => refreshed);
    const gate = createFreshnessGate({
      readExpiry: () => 2_000_000,
      now: () => 1_000_000,
      refresh
    });

    await expect(gate()).resolves.toEqual({ status: "fresh" });
    expect(refresh).not.toHaveBeenCalled();
  });

  it("refreshes when stale, and passes the outcome through", async () => {
    const refresh = vi.fn(async () => refreshed);
    const gate = createFreshnessGate({
      readExpiry: () => 1_000_100,
      now: () => 1_000_000,
      refresh
    });

    await expect(gate()).resolves.toEqual(refreshed);
    expect(refresh).toHaveBeenCalledTimes(1);
  });

  it("NO REFRESH STORM: a tab waking up fires many gates, the server sees ONE rotation", async () => {
    // The real wiring: the gate composes with the SAME single-flight the 401 path uses. Twenty
    // concurrent callers — a poll, a visibilitychange, and every in-flight request meeting 401 at
    // once — must not become twenty rotations, which the server would read as token reuse.
    let networkCalls = 0;
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });

    const single = createSingleFlight<RefreshOutcome>(async () => {
      networkCalls += 1;
      await gate;
      return refreshed;
    });

    const freshness = createFreshnessGate({
      readExpiry: () => 0, // always stale
      now: () => 1_000_000,
      refresh: single
    });

    const all = Promise.all(Array.from({ length: 20 }, () => freshness()));
    release();

    expect(await all).toEqual(Array(20).fill(refreshed));
    expect(networkCalls).toBe(1);
  });

  it("a transient failure is passed through, not swallowed into 'fresh'", async () => {
    const failure: RefreshOutcome = { status: "failed", reason: "network error" };
    const gate = createFreshnessGate({
      readExpiry: () => null,
      now: () => 1_000_000,
      refresh: async () => failure
    });

    await expect(gate()).resolves.toEqual(failure);
  });
});

describe("resolveAccessExpiry — both shapes the server uses", () => {
  const now = 1_700_000_000_000;

  it("turns the relative TTL (otp verify, refresh) into an absolute instant", () => {
    expect(resolveAccessExpiry({ accessTokenExpiresInSeconds: 900 }, now)).toBe(now + 900_000);
  });

  it("parses the absolute ISO expiry (QR link approval)", () => {
    expect(resolveAccessExpiry({ accessExpiresAt: "2026-09-24T10:00:00.000Z" }, now)).toBe(
      Date.parse("2026-09-24T10:00:00.000Z")
    );
  });

  it("prefers the relative form when both are present", () => {
    expect(
      resolveAccessExpiry(
        { accessTokenExpiresInSeconds: 60, accessExpiresAt: "2030-01-01T00:00:00.000Z" },
        now
      )
    ).toBe(now + 60_000);
  });

  it("is null for absent or unparseable input — never a bogus instant", () => {
    expect(resolveAccessExpiry({}, now)).toBeNull();
    expect(resolveAccessExpiry({ accessExpiresAt: "not a date" }, now)).toBeNull();
    expect(resolveAccessExpiry({ accessTokenExpiresInSeconds: Number.NaN }, now)).toBeNull();
  });
});
