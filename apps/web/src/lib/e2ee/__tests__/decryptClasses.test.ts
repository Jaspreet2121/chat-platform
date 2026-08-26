// Node environment, like the other e2ee suites (libsodium rejects jsdom's TextEncoder output).
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

/**
 * The four decrypt failure classes, the rotation cache invalidation, and the sealed-MEDIA render
 * path. These exist because production showed a thread of identical "Couldn't decrypt this message"
 * stubs — including the user's OWN messages — with no way to tell from the screenshot whether the
 * cause was a missing envelope, a key misalignment, a stale signing key, or our own frame bug.
 */

const registryDevices = vi.fn(async () => [] as Array<Record<string, unknown>>);

vi.mock("@/lib/api", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/lib/api")>();
  return {
    ...actual,
    fetchUserKeys: async (ids: string[]) =>
      Promise.all(ids.map(async (id) => ({ user_id: id, devices: await registryDevices() }))),
    uploadDeviceKeys: vi.fn(async () => ({ saved: true })),
    sendSealedMessage: vi.fn(),
    getSealedMediaDownloadUrl: vi.fn(),
    enableEncryption: vi.fn(),
    fetchClientConfig: vi.fn(async () => ({ e2ee_default: true }))
  };
});

// Built INSIDE the factory: vi.mock is hoisted above every module-level binding, so a captured
// outer `let` would still be in its temporal dead zone when this runs.
vi.mock("@/lib/e2ee/identity", async () => {
  const { sodiumReady } = await import("@/lib/e2ee/sodium");
  const sodium = await sodiumReady();
  const sign = sodium.crypto_sign_keypair();
  const box = sodium.crypto_box_keypair();

  const own = {
    deviceId: "web-me",
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

import { sealFrame } from "@/lib/e2ee/frame";
import { loadOrCreateIdentity } from "@/lib/e2ee/identity";
import { sodiumReady } from "@/lib/e2ee/sodium";
import { canonicalBytes, type FrameCleartext, type MediaDescriptor } from "@/lib/e2ee/canonical";
import {
  __clearCaches,
  decryptMessage,
  invalidateKeyCaches,
  setOwnUserId,
  type DecryptOutcome
} from "@/lib/e2ee/secretChat";
import type { Message } from "@/lib/api";

const CONV = "33333333-3333-3333-3333-333333333333";
const PEER = "22222222-2222-2222-2222-222222222222";

const b64 = async (bytes: Uint8Array) => {
  const sodium = await sodiumReady();
  return sodium.to_base64(bytes, sodium.base64_variants.ORIGINAL);
};

/** The row the server delivers — identical shape for a socket broadcast and a backfill page. */
function row(sealed: unknown, messageId: string): Message {
  return {
    message_id: messageId,
    conversation_id: CONV,
    sender_user_id: PEER,
    message_type: "sealed",
    body: null,
    metadata: { sealed },
    created_at: "2026-08-26T09:00:00.000Z"
  } as unknown as Message;
}

const textFrame = (body: string): FrameCleartext => ({
  v: 1,
  sender_user_id: PEER,
  sender_device_id: "web-peer",
  conversation_id: CONV,
  client_msg_id: "cid",
  composed_at: "2026-08-26T09:00:00.000Z",
  message_type: "text",
  body
});

/** A registry entry for the PEER's sending device, with whatever ed25519 key the test wants. */
async function peerRegistry(edPublic: Uint8Array, xPublic: Uint8Array) {
  return [
    {
      device_id: "web-peer",
      ed25519_public: await b64(edPublic),
      x25519_public: await b64(xPublic)
    }
  ];
}

let peerSign: { publicKey: Uint8Array; privateKey: Uint8Array };
let peerBox: { publicKey: Uint8Array; privateKey: Uint8Array };
let identity: Awaited<ReturnType<typeof loadOrCreateIdentity>>;

beforeEach(async () => {
  const sodium = await sodiumReady();
  identity = await loadOrCreateIdentity();
  peerSign = sodium.crypto_sign_keypair();
  peerBox = sodium.crypto_box_keypair();
  __clearCaches();
  setOwnUserId(null);
  registryDevices.mockResolvedValue(await peerRegistry(peerSign.publicKey, peerBox.publicKey));
  vi.spyOn(console, "warn").mockImplementation(() => undefined);
});

afterEach(() => vi.restoreAllMocks());

describe("decrypt failure classes", () => {
  it("missing_envelope — sealed to devices this browser isn't one of", async () => {
    const sodium = await sodiumReady();
    const other = sodium.crypto_box_keypair();

    const sealed = await sealFrame(textFrame("before this device existed"), peerSign.privateKey, "web-peer", [
      { device_id: "some-other-device", x25519_public: await b64(other.publicKey) }
    ]);

    expect(await decryptMessage(row(sealed, "m-missing"))).toEqual({
      ok: false,
      reason: "missing_envelope"
    });
  });

  it("open_failed — my envelope exists but was sealed to a DIFFERENT public key of mine", async () => {
    const sodium = await sodiumReady();
    const stale = sodium.crypto_box_keypair(); // the key the registry used to hold for this device

    const sealed = await sealFrame(textFrame("sealed to my old key"), peerSign.privateKey, "web-peer", [
      { device_id: identity.deviceId, x25519_public: await b64(stale.publicKey) }
    ]);

    // THE PRODUCTION SIGNATURE: addressed to me, unopenable by me — a key misalignment, and the
    // reason the user's OWN messages failed too (a sender seals to the registry's key).
    expect(await decryptMessage(row(sealed, "m-open"))).toEqual({
      ok: false,
      reason: "open_failed"
    });
  });

  it("sig_failed — opens, but the registry key doesn't match the signer", async () => {
    const sodium = await sodiumReady();
    const impostor = sodium.crypto_sign_keypair();

    const sealed = await sealFrame(textFrame("who signed this?"), peerSign.privateKey, "web-peer", [
      { device_id: identity.deviceId, x25519_public: await b64(identity.x25519Public) }
    ]);

    // The registry hands back the WRONG signing key, and keeps doing so on the forced refetch.
    registryDevices.mockResolvedValue(await peerRegistry(impostor.publicKey, peerBox.publicKey));

    expect(await decryptMessage(row(sealed, "m-sig"))).toEqual({ ok: false, reason: "sig_failed" });
  });

  it("inner_parse_failed — opens and VERIFIES, but the cleartext isn't a valid frame (our bug)", async () => {
    const sodium = await sodiumReady();

    // Hand-build a frame: sign + seal bytes that are not a valid FrameCleartext.
    const junk = new TextEncoder().encode('{"v":1,"body":42}');
    const sig = sodium.crypto_sign_detached(junk, peerSign.privateKey);
    const box = sodium.crypto_box_seal(junk, identity.x25519Public);

    const sealed = {
      v: 1,
      alg: "xsalsa20poly1305-sealedbox+ed25519",
      sender_device_id: "web-peer",
      sig_b64: await b64(sig),
      recipients: [{ device_id: identity.deviceId, envelope_b64: await b64(box) }]
    };

    expect(await decryptMessage(row(sealed, "m-parse"))).toEqual({
      ok: false,
      reason: "inner_parse_failed"
    });
  });

  it("no_frame — the row carries no sealed payload at all", async () => {
    const bare = { ...row(undefined, "m-none"), metadata: {} } as unknown as Message;
    expect(await decryptMessage(bare)).toEqual({ ok: false, reason: "no_frame" });
  });

  it("every failure is console.warn'd with its class AND the message id", async () => {
    const warn = console.warn as unknown as ReturnType<typeof vi.fn>;
    const bare = { ...row(undefined, "m-logged"), metadata: {} } as unknown as Message;
    await decryptMessage(bare);

    expect(warn).toHaveBeenCalled();
    const line = String(warn.mock.calls.at(-1)?.[0]);
    expect(line).toContain("no_frame");
    expect(line).toContain("m-logged");
  });
});

describe("rotation invalidates cached key material", () => {
  it("drops the CACHED FAILURE so a message re-decrypts once keys re-align", async () => {
    const sodium = await sodiumReady();
    const impostor = sodium.crypto_sign_keypair();

    const sealed = await sealFrame(textFrame("recovered"), peerSign.privateKey, "web-peer", [
      { device_id: identity.deviceId, x25519_public: await b64(identity.x25519Public) }
    ]);

    // First pass: the registry is stale (wrong signing key) → sig_failed, and that failure is cached.
    registryDevices.mockResolvedValue(await peerRegistry(impostor.publicKey, peerBox.publicKey));
    expect(await decryptMessage(row(sealed, "m-rot"))).toEqual({ ok: false, reason: "sig_failed" });

    // The peer rotates; the registry now serves their real key.
    registryDevices.mockResolvedValue(await peerRegistry(peerSign.publicKey, peerBox.publicKey));

    // WITHOUT invalidation the LRU keeps serving the cached failure forever — this is the mutation
    // point: comment out the negative-entry sweep in invalidateKeyCaches and this assertion fails.
    invalidateKeyCaches();

    expect(await decryptMessage(row(sealed, "m-rot"))).toMatchObject({
      ok: true,
      kind: "text",
      body: "recovered"
    });
  });

  it("keeps SUCCESSFUL decrypts cached (they cost CPU and can't go stale)", async () => {
    const sealed = await sealFrame(textFrame("still here"), peerSign.privateKey, "web-peer", [
      { device_id: identity.deviceId, x25519_public: await b64(identity.x25519Public) }
    ]);

    expect(await decryptMessage(row(sealed, "m-keep"))).toMatchObject({ ok: true });

    invalidateKeyCaches();

    // Registry now returns nothing at all; a cached success must still render.
    registryDevices.mockResolvedValue([]);
    expect(await decryptMessage(row(sealed, "m-keep"))).toMatchObject({ ok: true, kind: "text" });
  });

  it("scoped invalidation leaves an UNNAMED user's cached signing key in place", async () => {
    const first = await sealFrame(textFrame("scoped a"), peerSign.privateKey, "web-peer", [
      { device_id: identity.deviceId, x25519_public: await b64(identity.x25519Public) }
    ]);
    expect(await decryptMessage(row(first, "m-scope-1"))).toMatchObject({ ok: true });

    // Rotate a DIFFERENT user. The peer's signing key must survive in the cache.
    invalidateKeyCaches("99999999-9999-9999-9999-999999999999");
    registryDevices.mockResolvedValue([]);

    // A NEW message from the peer still verifies — only possible from the retained cached key.
    const second = await sealFrame(textFrame("scoped b"), peerSign.privateKey, "web-peer", [
      { device_id: identity.deviceId, x25519_public: await b64(identity.x25519Public) }
    ]);
    expect(await decryptMessage(row(second, "m-scope-2"))).toMatchObject({
      ok: true,
      body: "scoped b"
    });
  });
});

describe("sealed MEDIA renders through the same path on every delivery shape", () => {
  const media: MediaDescriptor = {
    media_id: "media-1",
    mime: "image/jpeg",
    size: 500,
    name: "photo.jpg",
    sha256_of_ciphertext: "deadbeef",
    enc: { alg: "secretstream-xchacha20poly1305", header_b64: "H", chunk_size: 65536 },
    key_b64: "K"
  };

  const mediaFrame: FrameCleartext = {
    v: 1,
    sender_user_id: PEER,
    sender_device_id: "web-peer",
    conversation_id: CONV,
    client_msg_id: "cid-media",
    composed_at: "2026-08-26T09:00:00.000Z",
    message_type: "media",
    body: "",
    media
  };

  async function sealMedia() {
    return sealFrame(mediaFrame, peerSign.privateKey, "web-peer", [
      { device_id: identity.deviceId, x25519_public: await b64(identity.x25519Public) }
    ]);
  }

  function assertRendersMediaBubble(outcome: DecryptOutcome) {
    // kind === "media" is exactly what MessageBubble branches on to mount SealedMediaBubble; the
    // generic stub is what a media frame must NEVER fall through to.
    expect(outcome.ok).toBe(true);
    if (!outcome.ok) return;
    expect(outcome.kind).toBe("media");
    if (outcome.kind !== "media") return;
    expect(outcome.media).toEqual(media);
  }

  it("a SOCKET-shaped row opens as media", async () => {
    assertRendersMediaBubble(await decryptMessage(row(await sealMedia(), "m-media-socket")));
  });

  it("a BACKFILL-shaped row opens as media (same metadata.sealed shape)", async () => {
    // Backfill rows carry the extra aggregate fields a broadcast doesn't; none of them affect this.
    const backfill = {
      ...row(await sealMedia(), "m-media-backfill"),
      read_by_count: 1,
      delivered_by_count: 1,
      reactions: [],
      is_starred: false
    } as unknown as Message;

    assertRendersMediaBubble(await decryptMessage(backfill));
  });

  it("the media descriptor survives canonicalisation byte-for-byte (no field drift)", async () => {
    // If the inner payload's shape ever drifts from E2EE_FRAME.md §media, the open would classify as
    // inner_parse_failed and render the generic stub — this catches it at the source.
    const bytes = canonicalBytes(mediaFrame);
    const reparsed = JSON.parse(new TextDecoder().decode(bytes)) as FrameCleartext;
    expect(reparsed.message_type).toBe("media");
    if (reparsed.message_type !== "media") return;
    expect(reparsed.media).toEqual(media);
  });
});
