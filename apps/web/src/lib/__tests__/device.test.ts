// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from "vitest";
import { deviceDisplayName, getOrCreateDeviceId } from "@/lib/device";

/**
 * TIER 1 — device identity. This has ALREADY regressed once: every web login sent the constant
 * "web-browser", so `UNIQUE (user_id, device_id)` collapsed every browser on every machine into ONE
 * device_sessions row — the linked-devices list showed a single anonymous entry and revoking it signed
 * out every browser at once. These tests pin the properties that made that a bug.
 *
 * The one file that needs browser globals, hence the jsdom docblock (the suite is node by default).
 */

beforeEach(() => window.localStorage.clear());

describe("getOrCreateDeviceId", () => {
  it("is NOT the historical constant, and is per-browser unique", () => {
    const id = getOrCreateDeviceId();

    expect(id).not.toBe("web-browser");
    expect(id).toMatch(/^web-/);
    // A UUID's worth of entropy — two fresh browsers must not collide.
    expect(id.length).toBeGreaterThan(20);
  });

  it("PERSISTS: the same browser keeps one id across calls and reloads", () => {
    const first = getOrCreateDeviceId();

    expect(getOrCreateDeviceId()).toBe(first);
    // Survives a "reload" — the value comes back from storage, not a fresh mint.
    expect(window.localStorage.getItem("chat_device_id")).toBe(first);
    expect(getOrCreateDeviceId()).toBe(first);
  });

  it("a DIFFERENT browser (cleared storage) gets a different id", () => {
    const first = getOrCreateDeviceId();
    window.localStorage.clear();

    expect(getOrCreateDeviceId()).not.toBe(first);
  });
});

describe("deviceDisplayName", () => {
  it("composes a human label CLIENT-side (no server user-agent fingerprinting)", () => {
    // jsdom's UA is a Mozilla/5.0 … string; the label must be human, never the raw UA.
    const name = deviceDisplayName();

    expect(name).toBeTruthy();
    expect(name).not.toContain("Mozilla/5.0");
    expect(name.length).toBeLessThan(40);
  });
});
