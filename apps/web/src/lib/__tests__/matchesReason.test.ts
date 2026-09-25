import { describe, expect, it } from "vitest";
import {
  REASON_TTL_MS,
  parseStoredReason,
  reasonIsFresh,
  reasonIsValid
} from "@/lib/matchesReason";

describe("reasonIsValid", () => {
  it("matches the floor the server enforces", () => {
    expect(reasonIsValid("abuse report #4410")).toBe(true);
    // "x" is not a reason, and neither is a box of spaces.
    expect(reasonIsValid("x")).toBe(false);
    expect(reasonIsValid("            ")).toBe(false);
    expect(reasonIsValid("")).toBe(false);
    expect(reasonIsValid(null)).toBe(false);
    expect(reasonIsValid(undefined)).toBe(false);
  });

  it("rejects one longer than the server will store", () => {
    expect(reasonIsValid("a".repeat(200))).toBe(true);
    expect(reasonIsValid("a".repeat(201))).toBe(false);
  });
});

describe("reasonIsFresh", () => {
  const now = 1_700_000_000_000;

  it("lasts an hour and not a minute longer", () => {
    expect(reasonIsFresh({ reason: "abuse report", at: now - 1000 }, now)).toBe(true);
    expect(reasonIsFresh({ reason: "abuse report", at: now - REASON_TTL_MS + 1 }, now)).toBe(true);
    expect(reasonIsFresh({ reason: "abuse report", at: now - REASON_TTL_MS }, now)).toBe(false);
  });

  it("refuses a reason stamped in the future", () => {
    // A skewed clock would otherwise give a reason that never expires.
    expect(reasonIsFresh({ reason: "abuse report", at: now + 5000 }, now)).toBe(false);
  });

  it("refuses a stored reason that is not a valid reason at all", () => {
    expect(reasonIsFresh({ reason: "x", at: now }, now)).toBe(false);
    expect(reasonIsFresh(null, now)).toBe(false);
    expect(reasonIsFresh({ reason: "abuse report", at: NaN }, now)).toBe(false);
  });
});

describe("parseStoredReason", () => {
  it("reads back what was written", () => {
    expect(parseStoredReason('{"reason":"abuse report","at":5}')).toEqual({
      reason: "abuse report",
      at: 5
    });
  });

  it("treats anything unreadable as absent rather than throwing", () => {
    // Storage can hold whatever an older build, or a person with devtools, put there.
    expect(parseStoredReason(null)).toBeNull();
    expect(parseStoredReason("not json")).toBeNull();
    expect(parseStoredReason('{"reason":5,"at":5}')).toBeNull();
    expect(parseStoredReason('{"reason":"abuse report"}')).toBeNull();
  });
});
