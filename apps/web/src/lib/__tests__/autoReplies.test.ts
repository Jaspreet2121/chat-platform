// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { getAutoReplies, updateAutoReplies, type AutoReplyAway, type AutoReplyGreeting } from "@/lib/api";
import {
  buildAway,
  buildGreeting,
  defaultSchedule,
  greetingWithDefaults,
  validateAway,
  validateGreeting,
  withDefaults
} from "@/lib/autoReplies";
import { installFetch, json, type RecordedCall } from "./support/fetchMock";

/**
 * Auto-replies (102). The PATCH semantics are the sharp edge: the server REPLACES each block it
 * receives wholesale and leaves an omitted block untouched. So the payload builder must emit a
 * COMPLETE, correctly-shaped block — a stray field or a missing one silently rewrites settings.
 */

const body = (calls: RecordedCall[], n = 0) => calls[n].body as Record<string, unknown>;

const away = (over: Partial<AutoReplyAway> = {}): AutoReplyAway => ({
  enabled: true,
  mode: "always",
  schedule: null,
  audience: "everyone",
  except_ids: [],
  body: "Away right now",
  ...over
});

const greeting = (over: Partial<AutoReplyGreeting> = {}): AutoReplyGreeting => ({
  enabled: true,
  audience: "everyone",
  except_ids: [],
  body: "Hi there",
  resend_after_days: 14,
  ...over
});

afterEach(() => vi.unstubAllGlobals());

describe("away payload build", () => {
  it("'always' sends schedule: null — never a stale schedule the server would ignore", () => {
    const built = buildAway(away({ mode: "always", schedule: defaultSchedule() }));
    expect(built.schedule).toBeNull();
    expect(built.mode).toBe("always");
  });

  it("'custom' keeps the schedule, and supplies a default one if the user never edited it", () => {
    const withSchedule = buildAway(away({ mode: "custom", schedule: null }));
    expect(withSchedule.schedule?.timezone).toBeTruthy();
    expect(withSchedule.schedule?.ranges.length).toBeGreaterThan(0);
  });

  it("except_ids ride ONLY the 'except' audience — switching away clears them", () => {
    const excluded = buildAway(away({ audience: "except", except_ids: ["u1", "u2"] }));
    expect(excluded.except_ids).toEqual(["u1", "u2"]);

    // The stale-exclusion bug: keeping the list while the audience is "everyone" would silently
    // exclude people the user thought they'd stopped excluding.
    const everyone = buildAway(away({ audience: "everyone", except_ids: ["u1", "u2"] }));
    expect(everyone.except_ids).toEqual([]);
  });

  it("a blank body is sent as null, not an empty string", () => {
    expect(buildAway(away({ enabled: false, body: "   " })).body).toBeNull();
    expect(buildAway(away({ body: "  hello  " })).body).toBe("hello");
  });
});

describe("greeting payload build", () => {
  it("carries the full block including resend_after_days", () => {
    expect(buildGreeting(greeting({ resend_after_days: 30 }))).toEqual({
      enabled: true,
      audience: "everyone",
      except_ids: [],
      body: "Hi there",
      resend_after_days: 30
    });
  });
});

describe("local validation mirrors the server", () => {
  it("an ENABLED block needs a body; a disabled one does not", () => {
    expect(validateAway(away({ enabled: true, body: "" }))).toBe("body_required");
    expect(validateAway(away({ enabled: false, body: "" }))).toBeNull();
    expect(validateGreeting(greeting({ enabled: true, body: "  " }))).toBe("body_required");
  });

  it("custom mode needs a timezone and at least one range, with valid days + times", () => {
    expect(validateAway(away({ mode: "custom", schedule: null }))).toBe("schedule_required");
    expect(
      validateAway(away({ mode: "custom", schedule: { timezone: "UTC", ranges: [] } }))
    ).toBe("schedule_required");
    expect(
      validateAway(
        away({ mode: "custom", schedule: { timezone: "UTC", ranges: [{ days: [], start: "09:00", end: "17:00" }] } })
      )
    ).toBe("no_days");
    expect(
      validateAway(
        away({ mode: "custom", schedule: { timezone: "UTC", ranges: [{ days: [1], start: "9am", end: "17:00" }] } })
      )
    ).toBe("invalid_time");
  });

  it("a midnight-crossing window is VALID (start > end is legal)", () => {
    expect(
      validateAway(
        away({
          mode: "custom",
          schedule: { timezone: "UTC", ranges: [{ days: [1], start: "18:00", end: "09:00" }] }
        })
      )
    ).toBeNull();
  });

  it("resend_after_days must be an integer in 1..365", () => {
    expect(validateGreeting(greeting({ resend_after_days: 0 }))).toBe("invalid_resend");
    expect(validateGreeting(greeting({ resend_after_days: 366 }))).toBe("invalid_resend");
    expect(validateGreeting(greeting({ resend_after_days: 1.5 }))).toBe("invalid_resend");
    expect(validateGreeting(greeting({ resend_after_days: 365 }))).toBeNull();
  });

  it("bodies over 500 characters are refused before the round-trip", () => {
    expect(validateAway(away({ body: "x".repeat(501) }))).toBe("body_too_long");
  });
});

describe("GET normalisation", () => {
  it("fills in except_ids the server omits on a never-written greeting", () => {
    const raw = { enabled: false, audience: "everyone", body: null, resend_after_days: 14 } as AutoReplyGreeting;
    expect(greetingWithDefaults(raw).except_ids).toEqual([]);
    expect(withDefaults({ ...away(), except_ids: undefined }).except_ids).toEqual([]);
  });
});

describe("the wire", () => {
  it("GET reads /api/v1/auto-replies", async () => {
    const calls = installFetch(() => json({ away: away(), greeting: greeting() }));
    await getAutoReplies();
    expect(calls[0].url).toContain("/api/v1/auto-replies");
    expect(calls[0].method).toBe("GET");
  });

  it("PATCH sends ONLY the edited block, so the other is left untouched server-side", async () => {
    const calls = installFetch(() => json({ away: away(), greeting: greeting() }));

    await updateAutoReplies({ away: buildAway(away()) });

    expect(calls[0].method).toBe("PATCH");
    const sent = body(calls);
    expect(sent).toHaveProperty("away");
    expect(sent).not.toHaveProperty("greeting");
  });
});
