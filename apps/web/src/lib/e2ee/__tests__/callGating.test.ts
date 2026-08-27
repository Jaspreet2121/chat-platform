// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { __resetCallE2eeSupport, callE2eeSupported } from "@/lib/e2ee/callKey";

/**
 * The two GATES that decide whether frame encryption is on, isolated from React.
 *
 * They matter more than the crypto: getting either wrong produces a call that connects and then
 * sounds like static, which is strictly worse than an honest unencrypted call.
 */

// The pure decision the CallProvider makes on each side. Kept here as executable documentation of
// §10.5's fallback table — the provider calls the same predicates inline.
function callerShouldEncrypt(input: { heldKey: boolean; acceptedFlag: unknown }): boolean {
  // Only an explicit `true` counts: false, absent, and an old client that sends nothing all mean the
  // peer is publishing plaintext frames.
  return input.heldKey && input.acceptedFlag === true;
}

function calleeShouldEncrypt(input: { supported: boolean; openedKey: boolean }): boolean {
  return input.supported && input.openedKey;
}

/** What the history row's lock badge reads. */
function historyShowsLock(row: { e2ee?: boolean; e2ee_accepted?: boolean | null }): boolean {
  return Boolean(row.e2ee && row.e2ee_accepted);
}

beforeEach(() => __resetCallE2eeSupport());
afterEach(() => vi.restoreAllMocks());

describe("browser capability gating (§10.5)", () => {
  it("reports supported when livekit says so, and caches the answer", async () => {
    vi.spyOn(console, "info").mockImplementation(() => undefined);
    vi.doMock("livekit-client", () => ({ isE2EESupported: () => true }));

    expect(await callE2eeSupported()).toBe(true);
    // Cached: a browser's capability does not change mid-session, and the log fires once.
    expect(await callE2eeSupported()).toBe(true);
    expect(console.info).toHaveBeenCalledTimes(1);
    vi.doUnmock("livekit-client");
  });

  it("an unsupported browser (Safari) behaves as a KEYLESS client in both directions", () => {
    // Callee side: never opens, always accepts plain.
    expect(calleeShouldEncrypt({ supported: false, openedKey: true })).toBe(false);
    // Caller side: with no support it never builds an offer, so it holds no key.
    expect(callerShouldEncrypt({ heldKey: false, acceptedFlag: true })).toBe(false);
  });
});

describe("caller enable-gating on e2ee_accepted (§10.5)", () => {
  it("encrypts ONLY when it holds a key AND the accept said true", () => {
    expect(callerShouldEncrypt({ heldKey: true, acceptedFlag: true })).toBe(true);
  });

  it("does NOT encrypt when the callee declined, omitted the flag, or is an old client", () => {
    // Encrypting here would send frames the peer decodes as garbage audio.
    expect(callerShouldEncrypt({ heldKey: true, acceptedFlag: false })).toBe(false);
    expect(callerShouldEncrypt({ heldKey: true, acceptedFlag: undefined })).toBe(false);
    expect(callerShouldEncrypt({ heldKey: true, acceptedFlag: null })).toBe(false);
    // Truthy-but-not-true must not slip through.
    expect(callerShouldEncrypt({ heldKey: true, acceptedFlag: "true" })).toBe(false);
    expect(callerShouldEncrypt({ heldKey: true, acceptedFlag: 1 })).toBe(false);
  });

  it("never encrypts without a key, whatever the peer claims", () => {
    expect(callerShouldEncrypt({ heldKey: false, acceptedFlag: true })).toBe(false);
  });
});

describe("callee accept decision (§10.3)", () => {
  it("accepts true only when it actually opened its envelope", () => {
    expect(calleeShouldEncrypt({ supported: true, openedKey: true })).toBe(true);
    // missing_envelope / open_failed / no_offer all land here → accept false, call proceeds plain.
    expect(calleeShouldEncrypt({ supported: true, openedKey: false })).toBe(false);
  });
});

describe("history lock badge", () => {
  it("shows only for a call that ran encrypted end to end", () => {
    expect(historyShowsLock({ e2ee: true, e2ee_accepted: true })).toBe(true);
  });

  it("stays off for an OFFERED call that fell back to plain — it must not over-claim", () => {
    expect(historyShowsLock({ e2ee: true, e2ee_accepted: false })).toBe(false);
    // Never answered → no media, no claim.
    expect(historyShowsLock({ e2ee: true, e2ee_accepted: null })).toBe(false);
    expect(historyShowsLock({ e2ee: false })).toBe(false);
    expect(historyShowsLock({})).toBe(false);
  });
});
