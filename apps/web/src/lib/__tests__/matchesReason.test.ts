import { describe, expect, it } from "vitest";
import {
  REASON_TTL_MS,
  parseStoredReason,
  reasonIsFresh,
  reasonIsValid,
  validateReason
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
    expect(reasonIsValid("valid words ".repeat(20))).toBe(false);
    expect(validateReason("valid words ".repeat(20))).toEqual({
      ok: false,
      why: "at most 200 characters"
    });
  });

  it("mirrors the server rule for one word, no vowels and repeated junk — with the same wording", () => {
    // These are the strings an operator could type to get past a length check while telling the
    // audit reader nothing. Same examples, same messages as SharedInfra.ReasonPolicyTest.
    const refused: Array<[string, string]> = [
      ["abuse rep", "at least 12 characters"],
      ["investigation", "at least two words"],
      ["hjzgjcgz hjzgjcgz", "real words — nothing here has a vowel"],
      ["asdfasdf asdfasdf", "repeated characters are not a reason"],
      ["abuse abuse abuse", "repeated characters are not a reason"],
      ["aaaaaaaaaaaa report", "repeated characters are not a reason"]
    ];
    for (const [value, why] of refused) {
      expect(validateReason(value)).toEqual({ ok: false, why });
    }
    expect(validateReason("  abuse   report   #4410 ")).toEqual({
      ok: true,
      reason: "abuse report #4410"
    });
    expect(validateReason("legal request LR-22").ok).toBe(true);
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
