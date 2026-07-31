import { describe, expect, it } from "vitest";
import { toE164, toE164Loose } from "@/lib/phone";

/**
 * TIER 1 — phone normalization. The backend stores and matches E.164 EXACTLY: by-phone lookup is a
 * string equality against `users_auth.phone_number`. So a regression here doesn't throw — the number
 * that looks right on screen simply stops matching, and "no account uses this number" is the only
 * symptom. Pure functions, no environment needed.
 */

describe("toE164 (country-picker path: login)", () => {
  it("normalizes a valid national number to E.164, ignoring the display formatting", () => {
    expect(toE164("IN", "98765 43210")).toBe("+919876543210");
    expect(toE164("IN", "(98765) 43210")).toBe("+919876543210");
    // Formatting must not change the wire value — that equality IS the lookup.
    expect(toE164("IN", "9876543210")).toBe(toE164("IN", "98765-43210"));
  });

  it("returns '' (never a partial/invalid number) so callers can gate submit", () => {
    expect(toE164("IN", "")).toBe("");
    expect(toE164("IN", "98765")).toBe("");
    expect(toE164("IN", "abc")).toBe("");
  });

  it("is country-scoped: the same digits differ per region", () => {
    expect(toE164("US", "4155552671")).toBe("+14155552671");
    expect(toE164("US", "4155552671")).not.toBe(toE164("GB", "4155552671"));
  });
});

describe("toE164Loose (region-less path: chat search / new conversation)", () => {
  it("accepts a full international number regardless of the default region", () => {
    expect(toE164Loose("+14155552671", "IN")).toBe("+14155552671");
    expect(toE164Loose("+1 415 555 2671", "IN")).toBe("+14155552671");
  });

  it("normalizes a bare national number using the default region", () => {
    expect(toE164Loose("9876543210", "IN")).toBe("+919876543210");
  });

  it("agrees with toE164 for the same number — one stored shape, two entry surfaces", () => {
    expect(toE164Loose("9876543210", "IN")).toBe(toE164("IN", "98765 43210"));
  });

  it("returns '' for empty/invalid input rather than a half-parsed number", () => {
    expect(toE164Loose("", "IN")).toBe("");
    expect(toE164Loose("+", "IN")).toBe("");
    expect(toE164Loose("12", "IN")).toBe("");
  });
});
