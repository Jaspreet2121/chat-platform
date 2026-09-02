// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { getNearbySettings, updateNearbySettings } from "@/lib/api";
import { bucketLabel, nearbyCta, stalenessLabel } from "@/components/chat/NearbyPeopleModal";
import { installFetch, json, type RecordedCall } from "./support/fetchMock";

/**
 * Nearby v2 (104) on the web: the settings round-trip (GET/PATCH /api/v1/nearby/settings) and the
 * distance-bucket label. The bucket matters because the gateway overwrites the numeric GPS bucket
 * with the STRING "ble" when a Bluetooth proximity marker is live — the old renderer interpolated it
 * blindly and produced "Within ble m".
 *
 * Also the per-row CTA mapping. The four relationship states each get a DIFFERENT control, and the
 * two that matter are opposites: an existing connection gets "Message" (opens the chat) while a
 * stranger gets "Send request" (fires a connection request). Swapping those two would silently
 * message people you have not connected to, or offer to befriend people you already chat with —
 * neither is a crash, so only an assertion catches it.
 *
 * SCOPE: this locks the LABELS and the branch identity, not the handler wiring. Which onClick each
 * kind is bound to lives in the JSX and needs a component renderer to assert; there is none in this
 * suite (see vitest.config.ts — the include glob is *.test.ts and nothing renders React), and
 * adding one is a separate infrastructure decision.
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

describe("nearby CTA mapping", () => {
  it("gives an existing connection a Message action", () => {
    expect(nearbyCta("connected")).toEqual({ kind: "message", label: "Message" });
  });

  it("gives a stranger a Send request action", () => {
    expect(nearbyCta("none")).toEqual({ kind: "request", label: "Send request" });
  });

  it("shows a sent request as pending, with no action", () => {
    expect(nearbyCta("sent")).toEqual({ kind: "requested", label: "Requested" });
  });

  it("points an incoming request at the list above, with no action", () => {
    expect(nearbyCta("received")).toEqual({ kind: "check", label: "Check request above" });
  });

  it("never gives two relationships the same control", () => {
    // The whole point of the mapping: four states, four distinct outcomes. A refactor that
    // collapses any pair — most dangerously connected and none — fails here even if each
    // individual assertion above were somehow satisfied.
    const all = (["connected", "none", "sent", "received"] as const).map(nearbyCta);

    expect(new Set(all.map((cta) => cta.kind)).size).toBe(4);
    expect(new Set(all.map((cta) => cta.label)).size).toBe(4);
  });

  it("falls through to Send request for an unrecognised relationship", () => {
    // PINNED BEHAVIOUR, not a preference: the ternary chain this replaced ended in an `else` that
    // caught "none" and anything unknown alike. A future fifth server value therefore offers a
    // request rather than rendering an empty row on an old client.
    const unknown = "blocked" as unknown as Parameters<typeof nearbyCta>[0];

    expect(nearbyCta(unknown)).toEqual({ kind: "request", label: "Send request" });
  });

  it("never returns a blank label", () => {
    for (const value of ["connected", "none", "sent", "received"] as const) {
      expect(nearbyCta(value).label.trim().length).toBeGreaterThan(0);
    }
  });
});

describe("staleness label (114)", () => {
  // The server sends a coarse ceiling bucket, never a timestamp — there is no minute count to
  // render and deliberately no way to derive one. These are the five words a viewer can ever see.
  it("renders each bucket as coarse words, never minutes", () => {
    expect(stalenessLabel("now")).toBe("Now");
    expect(stalenessLabel("1h")).toBe("~1h ago");
    expect(stalenessLabel("2h")).toBe("~2h ago");
    expect(stalenessLabel("4h")).toBe("~4h ago");
    expect(stalenessLabel("8h")).toBe("~8h ago");
  });

  it("gives every bucket a DISTINCT label — a collapse would hide staleness entirely", () => {
    const labels = (["now", "1h", "2h", "4h", "8h"] as const).map(stalenessLabel);

    expect(new Set(labels).size).toBe(5);
  });

  it("degrades honestly on a bucket this build does not know", () => {
    // A newer server adding a bucket must not render "undefined ago" in a list of real people.
    const unknown = "16h" as unknown as Parameters<typeof stalenessLabel>[0];

    expect(stalenessLabel(unknown)).toBe("Earlier");
    expect(stalenessLabel(unknown)).not.toMatch(/undefined|NaN/);
  });

  it("never renders a minute count", () => {
    for (const bucket of ["now", "1h", "2h", "4h", "8h"] as const) {
      expect(stalenessLabel(bucket)).not.toMatch(/\bmin/i);
    }
  });
});
