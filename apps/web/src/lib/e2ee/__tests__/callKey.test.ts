// Node environment, like the other e2ee suites (libsodium rejects jsdom's TextEncoder output).
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

/**
 * E2EE calls (E2EE_FRAME.md §10) on the web client.
 *
 * The two things that actually break a call are pinned here: WHO the key gets sealed to (miss the
 * self-copy and answering on a second own device is impossible; include a foreign device and the
 * server refuses the whole offer), and the AGREEMENT (enable frame encryption when the peer did not
 * and they hear garbage — worse than an honestly-unencrypted call).
 */

const fetchUserKeysMock =
  vi.fn<(ids: string[]) => Promise<Array<{ user_id: string; devices: unknown[] }>>>(async () => []);

vi.mock("@/lib/api", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/lib/api")>();
  return { ...actual, fetchUserKeys: (ids: string[]) => fetchUserKeysMock(ids) };
});

// Built inside the factory: vi.mock is hoisted above every module-level binding.
vi.mock("@/lib/e2ee/identity", async () => {
  const { sodiumReady } = await import("@/lib/e2ee/sodium");
  const sodium = await sodiumReady();
  const sign = sodium.crypto_sign_keypair();
  const box = sodium.crypto_box_keypair();

  const own = {
    deviceId: "my-phone",
    ed25519Public: sign.publicKey,
    ed25519Private: sign.privateKey,
    x25519Public: box.publicKey,
    x25519Private: box.privateKey
  };

  return {
    loadOrCreateIdentity: async () => own,
    publicKeysBase64: async () => ({
      ed25519: sodium.to_base64(own.ed25519Public, sodium.base64_variants.ORIGINAL),
      x25519: sodium.to_base64(own.x25519Public, sodium.base64_variants.ORIGINAL)
    })
  };
});

import { loadOrCreateIdentity } from "@/lib/e2ee/identity";
import { sodiumReady } from "@/lib/e2ee/sodium";
import {
  CALL_KEY_BYTES,
  buildCallOffer,
  callKeyToProviderKey,
  generateCallKey,
  openCallKey,
  wipeCallKey
} from "@/lib/e2ee/callKey";

const ME = "11111111-1111-1111-1111-111111111111";
const PEER = "22222222-2222-2222-2222-222222222222";

type Keypair = { publicKey: Uint8Array; privateKey: Uint8Array };

const b64 = async (bytes: Uint8Array) => {
  const sodium = await sodiumReady();
  return sodium.to_base64(bytes, sodium.base64_variants.ORIGINAL);
};

async function device(deviceId: string, box: Keypair) {
  return {
    device_id: deviceId,
    platform: "web",
    ed25519_public: await b64(box.publicKey),
    x25519_public: await b64(box.publicKey),
    key_fingerprint: "f",
    updated_at: "2026-08-27T00:00:00Z"
  };
}

let peerBox: Keypair;
let myOtherBox: Keypair;

beforeEach(async () => {
  const sodium = await sodiumReady();
  peerBox = sodium.crypto_box_keypair();
  myOtherBox = sodium.crypto_box_keypair();
  fetchUserKeysMock.mockReset();
  vi.spyOn(console, "warn").mockImplementation(() => undefined);
});

afterEach(() => vi.restoreAllMocks());

describe("call key", () => {
  it("is 32 cryptographically random bytes, fresh every call", async () => {
    const a = await generateCallKey();
    const b = await generateCallKey();

    expect(a.length).toBe(CALL_KEY_BYTES);
    expect(Array.from(a)).not.toEqual(Array.from(b));
  });

  it("maps to the provider key as BASE64 of the raw bytes (the §10.4 amendment)", async () => {
    const key = await generateCallKey();
    const providerKey = await callKeyToProviderKey(key);

    // A STRING, so livekit-client takes the PBKDF2 path it calls "recommended for maximum
    // compatibility across SDKs" — an ArrayBuffer would silently select HKDF, which not every SDK
    // supports, and Android would derive different material.
    expect(typeof providerKey).toBe("string");
    expect(providerKey).toBe(await b64(key));
    // 32 bytes → 44 padded base64 characters.
    expect(providerKey).toHaveLength(44);
  });

  it("is wiped, not merely dropped, when the call ends", async () => {
    const key = await generateCallKey();
    expect(key.some((byte) => byte !== 0)).toBe(true);

    wipeCallKey(key);

    expect(Array.from(key)).toEqual(new Array(CALL_KEY_BYTES).fill(0));
    // Wiping absent keys is a no-op, so teardown never has to branch.
    expect(() => wipeCallKey(null)).not.toThrow();
  });
});

describe("offer construction (§10.2)", () => {
  it("seals to EVERY callee device AND my own OTHER devices — never my sending device", async () => {
    fetchUserKeysMock.mockResolvedValue([
      { user_id: PEER, devices: [await device("peer-phone", peerBox), await device("peer-laptop", peerBox)] },
      {
        user_id: ME,
        // My CURRENT device plus one other. Only the other gets an envelope.
        devices: [await device("my-phone", myOtherBox), await device("my-laptop", myOtherBox)]
      }
    ]);

    const offer = await buildCallOffer({
      callKey: await generateCallKey(),
      myUserId: ME,
      calleeUserId: PEER
    });

    expect(offer).not.toBeNull();
    const ids = offer!.envelopes.map((e) => e.device_id).sort();

    // The self-copy is what makes answering on another own device possible.
    expect(ids).toEqual(["my-laptop", "peer-laptop", "peer-phone"]);
    // My sending device is excluded — I already hold the key, and every envelope costs budget.
    expect(ids).not.toContain("my-phone");
    expect(offer!.v).toBe(1);
    expect(offer!.sender_device_id).toBe("my-phone");
  });

  it("a KEYLESS callee yields NO offer — the call proceeds plain, with no error", async () => {
    fetchUserKeysMock.mockResolvedValue([
      { user_id: PEER, devices: [] },
      { user_id: ME, devices: [await device("my-laptop", myOtherBox)] }
    ]);

    expect(
      await buildCallOffer({ callKey: await generateCallKey(), myUserId: ME, calleeUserId: PEER })
    ).toBeNull();
  });

  it("a failed key fetch yields no offer rather than a thrown call", async () => {
    fetchUserKeysMock.mockRejectedValue(new Error("registry down"));

    expect(
      await buildCallOffer({ callKey: await generateCallKey(), myUserId: ME, calleeUserId: PEER })
    ).toBeNull();
  });

  it("stays within the server's 20-envelope cap", async () => {
    const many = await Promise.all(
      Array.from({ length: 30 }, (_, i) => device(`peer-${i}`, peerBox))
    );
    fetchUserKeysMock.mockResolvedValue([
      { user_id: PEER, devices: many },
      { user_id: ME, devices: [] }
    ]);

    const offer = await buildCallOffer({
      callKey: await generateCallKey(),
      myUserId: ME,
      calleeUserId: PEER
    });

    // Building 30 would make the server refuse the whole offer as invalid.
    expect(offer!.envelopes.length).toBeLessThanOrEqual(20);
  });
});

describe("accept-path decision matrix (§10.3)", () => {
  async function offerTo(deviceId: string, key: Uint8Array) {
    const sodium = await sodiumReady();
    const identity = await loadOrCreateIdentity();
    const target = deviceId === identity.deviceId ? identity.x25519Public : peerBox.publicKey;

    return {
      v: 1,
      sender_device_id: "caller-dev",
      envelopes: [
        {
          device_id: deviceId,
          envelope_b64: sodium.to_base64(
            sodium.crypto_box_seal(key, target),
            sodium.base64_variants.ORIGINAL
          )
        }
      ]
    };
  }

  it("MY envelope opens → the exact call key comes back (→ accept true, E2EE on)", async () => {
    const key = await generateCallKey();
    const result = await openCallKey(await offerTo("my-phone", key));

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(Array.from(result.callKey)).toEqual(Array.from(key));
  });

  it("NO envelope for this device → missing_envelope (→ accept false, plain call)", async () => {
    const result = await openCallKey(await offerTo("someone-elses-device", await generateCallKey()));
    expect(result).toEqual({ ok: false, reason: "missing_envelope" });
  });

  it("an envelope sealed to a DIFFERENT key of mine → open_failed (→ accept false, plain call)", async () => {
    const sodium = await sodiumReady();
    const stale = sodium.crypto_box_keypair();
    const key = await generateCallKey();

    const offer = {
      v: 1,
      sender_device_id: "caller-dev",
      envelopes: [
        {
          device_id: "my-phone",
          envelope_b64: sodium.to_base64(
            sodium.crypto_box_seal(key, stale.publicKey),
            sodium.base64_variants.ORIGINAL
          )
        }
      ]
    };

    expect(await openCallKey(offer)).toEqual({ ok: false, reason: "open_failed" });
  });

  it("NO offer at all (an old caller) → no_offer (→ accept false, plain call)", async () => {
    expect(await openCallKey(null)).toEqual({ ok: false, reason: "no_offer" });
    expect(await openCallKey({ v: 1, sender_device_id: "x", envelopes: [] })).toEqual({
      ok: false,
      reason: "no_offer"
    });
  });

  it("a wrong-LENGTH payload is refused rather than fed to the room", async () => {
    const sodium = await sodiumReady();
    const identity = await loadOrCreateIdentity();

    const offer = {
      v: 1,
      sender_device_id: "caller-dev",
      envelopes: [
        {
          device_id: "my-phone",
          envelope_b64: sodium.to_base64(
            // 16 bytes, not 32 — a room nobody could decode.
            sodium.crypto_box_seal(new Uint8Array(16), identity.x25519Public),
            sodium.base64_variants.ORIGINAL
          )
        }
      ]
    };

    expect(await openCallKey(offer)).toEqual({ ok: false, reason: "open_failed" });
  });
});

describe("round trip", () => {
  it("the caller's sealed key is exactly what the callee opens", async () => {
    const identity = await loadOrCreateIdentity();
    const callKey = await generateCallKey();

    // The "callee" here is this test identity, so buildCallOffer's output can be opened directly.
    fetchUserKeysMock.mockResolvedValue([
      {
        user_id: PEER,
        devices: [
          {
            device_id: identity.deviceId,
            platform: "web",
            ed25519_public: await b64(identity.ed25519Public),
            x25519_public: await b64(identity.x25519Public),
            key_fingerprint: "f",
            updated_at: "2026-08-27T00:00:00Z"
          }
        ]
      },
      { user_id: ME, devices: [] }
    ]);

    const offer = await buildCallOffer({ callKey, myUserId: ME, calleeUserId: PEER });
    const opened = await openCallKey(offer);

    expect(opened.ok).toBe(true);
    if (!opened.ok) return;
    expect(Array.from(opened.callKey)).toEqual(Array.from(callKey));
    // Both sides therefore feed the SAME provider string to LiveKit.
    expect(await callKeyToProviderKey(opened.callKey)).toBe(await callKeyToProviderKey(callKey));
  });
});
