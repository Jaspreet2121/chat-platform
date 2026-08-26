// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { getNearbySettings, updateNearbySettings } from "@/lib/api";
import { bucketLabel } from "@/components/chat/NearbyPeopleModal";
import { installFetch, json, type RecordedCall } from "./support/fetchMock";

/**
 * Nearby v2 (104) on the web: the settings round-trip (GET/PATCH /api/v1/nearby/settings) and the
 * distance-bucket label. The bucket matters because the gateway overwrites the numeric GPS bucket
 * with the STRING "ble" when a Bluetooth proximity marker is live — the old renderer interpolated it
 * blindly and produced "Within ble m".
 */

const body = (calls: RecordedCall[], n = 0) => calls[n].body as Record<string, unknown>;

afterEach(() => vi.unstubAllGlobals());

describe("nearby settings round-trip", () => {
  it("GETs the three v2 fields", async () => {
    const calls = installFetch(() =>
      json({ enabled: true, ble_assist: false, audience: "everyone" })
    );

    const settings = await getNearbySettings();

    expect(calls[0].url).toContain("/api/v1/nearby/settings");
    expect(calls[0].method).toBe("GET");
    expect(settings).toEqual({ enabled: true, ble_assist: false, audience: "everyone" });
  });

  it("PATCHes SPARSELY — only the changed key rides the request", async () => {
    const calls = installFetch(() =>
      json({ enabled: true, ble_assist: false, audience: "contacts" })
    );

    const updated = await updateNearbySettings({ audience: "contacts" });

    expect(calls[0].method).toBe("PATCH");
    // The server merges partials; sending the whole object would clobber keys another device changed.
    expect(body(calls)).toEqual({ audience: "contacts" });
    // The RESPONSE is authoritative — the UI renders this, not the optimistic value.
    expect(updated.audience).toBe("contacts");
  });

  it("can turn discoverability off (false is sent, not dropped as falsy)", async () => {
    const calls = installFetch(() =>
      json({ enabled: false, ble_assist: false, audience: "everyone" })
    );

    await updateNearbySettings({ enabled: false });

    expect(body(calls)).toEqual({ enabled: false });
  });
});

describe("distance bucket label", () => {
  it("renders the metre buckets as a distance", () => {
    expect(bucketLabel(100)).toBe("Within 100 m");
    expect(bucketLabel(200)).toBe("Within 200 m");
  });

  it("renders the BLE bucket as 'Very close', never 'Within ble m'", () => {
    expect(bucketLabel("ble")).toBe("Very close");
    expect(bucketLabel("ble")).not.toContain("m");
  });
});
