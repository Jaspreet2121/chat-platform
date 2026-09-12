// Node environment, like the other e2ee suites (libsodium rejects jsdom's TextEncoder output).
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

/**
 * THE KEY-REGISTRY CACHE STAMPEDE (2026-09-12).
 *
 * GET /api/v1/keys/users is limited to 30/60s per user, FAIL-CLOSED. `senderEd25519` used to check
 * its cache synchronously and populate it only AFTER the network resolved, so N parallel decrypts of
 * a cold thread all missed and all fetched the SAME user's keys in one tick: a 20-message sealed
 * chat sent 20 identical requests and the next send came back 429 "Too many requests".
 *
 * What is pinned here:
 *   * CONCURRENT misses for one user share ONE request (the in-flight map);
 *   * a REJECTED fetch is not cached — the next call retries, or one 429 would poison the session;
 *   * a multi-sender chat open costs ONE request, not one per sender (prefetchSenderKeys);
 *   * the send path reads the cache, and a ROTATION still refetches — the correctness pin, because
 *     sealing to a stale device key means the recipient cannot read the message.
 */

let fetchCalls: string[][] = [];
const registryDevices = vi.fn(async () => [] as Array<Record<string, unknown>>);
const realFetch = async (ids: string[]) => {
  fetchCalls.push(ids);
  return Promise.all(ids.map(async (id) => ({ user_id: id, devices: await registryDevices() })));
};
const fetchImpl = vi.fn(realFetch);
const sentSealed = vi.fn(async (input: unknown) => {
  sealedSends.push(input as { sealed: { recipients: Array<{ device_id: string; envelope_b64: string }> } });
  return { message_id: `m-sent-${sealedSends.length}` } as unknown as Message;
});
let sealedSends: Array<{ sealed: { recipients: Array<{ device_id: string; envelope_b64: string }> } }> = [];

vi.mock("@/lib/api", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/lib/api")>();
  return {
    ...actual,
    fetchUserKeys: (ids: string[]) => fetchImpl(ids),
    uploadDeviceKeys: vi.fn(async () => ({ saved: true })),
    sendSealedMessage: (input: unknown) => sentSealed(input),
    getSealedMediaDownloadUrl: vi.fn(),
    enableEncryption: vi.fn(),
    fetchClientConfig: vi.fn(async () => ({ e2ee_default: true }))
  };
});

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
import type { FrameCleartext } from "@/lib/e2ee/canonical";
import {
  __clearCaches,
  decryptMessage,
  invalidateKeyCaches,
  prefetchSenderKeys,
  sendSecretText,
  setOwnUserId
} from "@/lib/e2ee/secretChat";
import type { Message } from "@/lib/api";

const CONV = "33333333-3333-3333-3333-333333333333";
const PEER = "22222222-2222-2222-2222-222222222222";

const b64 = async (bytes: Uint8Array) => {
  const sodium = await sodiumReady();
  return sodium.to_base64(bytes, sodium.base64_variants.ORIGINAL);
};

function row(sealed: unknown, messageId: string, sender = PEER): Message {
  return {
    message_id: messageId,
    conversation_id: CONV,
    sender_user_id: sender,
    message_type: "sealed",
    body: null,
    metadata: { sealed },
    created_at: "2026-08-26T09:00:00.000Z"
  } as unknown as Message;
}

const textFrame = (body: string, sender = PEER): FrameCleartext => ({
  v: 1,
  sender_user_id: sender,
  sender_device_id: "web-peer",
  conversation_id: CONV,
  client_msg_id: "cid",
  composed_at: "2026-08-26T09:00:00.000Z",
  message_type: "text",
  body
});

let peerSign: { publicKey: Uint8Array; privateKey: Uint8Array };
let peerBox: { publicKey: Uint8Array; privateKey: Uint8Array };
let identity: Awaited<ReturnType<typeof loadOrCreateIdentity>>;

async function peerRegistry(edPublic: Uint8Array, xPublic: Uint8Array) {
  return [
    {
      device_id: "web-peer",
      ed25519_public: await b64(edPublic),
      x25519_public: await b64(xPublic)
    }
  ];
}

/** N distinct sealed messages from the same sender — a cold thread. */
async function sealedThread(count: number, prefix = "m") {
  const rows: Message[] = [];
  for (let i = 0; i < count; i += 1) {
    const sealed = await sealFrame(textFrame(`msg ${i}`), peerSign.privateKey, "web-peer", [
      { device_id: identity.deviceId, x25519_public: await b64(identity.x25519Public) }
    ]);
    // The id must be unique per call: decryptMessage caches outcomes (including FAILURES) by id,
    // so reusing ids would let the LRU answer a later pass and hide whether a refetch happened.
    rows.push(row(sealed, `${prefix}-${i}`));
  }
  return rows;
}

beforeEach(async () => {
  const sodium = await sodiumReady();
  identity = await loadOrCreateIdentity();
  peerSign = sodium.crypto_sign_keypair();
  peerBox = sodium.crypto_box_keypair();
  __clearCaches();
  setOwnUserId(null);
  fetchCalls = [];
  sealedSends = [];
  sentSealed.mockClear();
  fetchImpl.mockClear();
  fetchImpl.mockImplementation(realFetch);
  registryDevices.mockResolvedValue(await peerRegistry(peerSign.publicKey, peerBox.publicKey));
  vi.spyOn(console, "warn").mockImplementation(() => undefined);
});

afterEach(() => vi.restoreAllMocks());

describe("in-flight coalescing", () => {
  it("TWENTY concurrent decrypts of a cold thread make ONE registry request", async () => {
    const rows = await sealedThread(20);

    // Exactly the page's fan-out: every pending message decrypted in parallel, cold cache.
    const outcomes = await Promise.all(rows.map((r) => decryptMessage(r)));

    expect(outcomes.every((o) => o.ok)).toBe(true);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("a LATER batch of new messages from the same sender adds no request — the cache is warm", async () => {
    await Promise.all((await sealedThread(5)).map((r) => decryptMessage(r)));
    expect(fetchImpl).toHaveBeenCalledTimes(1);

    // FRESH message ids, so the decrypt LRU cannot mask a refetch: only the key cache can.
    const more = await sealedThread(5);
    const outcomes = await Promise.all(
      more.map((r) =>
        decryptMessage(
          row((r.metadata as { sealed: unknown }).sealed, `later-${r.message_id}`)
        )
      )
    );
    expect(outcomes.every((o) => o.ok)).toBe(true);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("a REJECTED fetch is NOT cached — the next call retries instead of failing forever", async () => {
    fetchImpl.mockRejectedValue(new Error("429 Too many requests"));

    // prefetch has no self-healing retry of its own, so it isolates the in-flight bookkeeping.
    await prefetchSenderKeys([PEER]);
    expect(fetchImpl).toHaveBeenCalledTimes(1);

    // A rejected promise left in the in-flight map (or a freshness stamp written on failure) would
    // make every later call a silent no-op — one 429 would blank this peer's keys for the session.
    await prefetchSenderKeys([PEER]);
    expect(fetchImpl).toHaveBeenCalledTimes(2);

    // ...and once the limiter recovers, the very next read succeeds.
    fetchImpl.mockImplementation(realFetch);
    const rows = await sealedThread(3, "after-429");
    const ok = await Promise.all(rows.map((r) => decryptMessage(r)));
    expect(ok.every((o) => o.ok)).toBe(true);
  });

  it("a REJECTED fetch on the DECRYPT path is not cached either — recovery is possible", async () => {
    // loadUserKeys keeps its OWN in-flight entry; if a rejected promise were left there, every
    // later decrypt for this peer would re-await the same failure for the rest of the session.
    fetchImpl.mockRejectedValue(new Error("429 Too many requests"));

    const during = await sealedThread(2, "outage");
    const failed = await Promise.all(during.map((r) => decryptMessage(r)));
    expect(failed.every((o) => !o.ok)).toBe(true);
    const callsWhileFailing = fetchImpl.mock.calls.length;
    expect(callsWhileFailing).toBeGreaterThanOrEqual(1);

    fetchImpl.mockImplementation(realFetch);

    const after = await sealedThread(2, "recovered");
    const ok = await Promise.all(after.map((r) => decryptMessage(r)));
    expect(ok.every((o) => o.ok)).toBe(true);
    expect(fetchImpl.mock.calls.length).toBeGreaterThan(callsWhileFailing);
  });
});

describe("batched prefetch (the chat-open path)", () => {
  it("MANY senders cost ONE request, not one per sender", async () => {
    const senders = Array.from({ length: 8 }, (_, i) => `1111111${i}-1111-4111-8111-111111111111`);

    await prefetchSenderKeys(senders);

    expect(fetchImpl).toHaveBeenCalledTimes(1);
    expect(fetchCalls[0]).toHaveLength(8);
    expect(new Set(fetchCalls[0])).toEqual(new Set(senders));
  });

  it("de-duplicates ids and skips users already cached", async () => {
    await prefetchSenderKeys([PEER, PEER, PEER]);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    expect(fetchCalls[0]).toEqual([PEER]);

    // Already fresh → no second request.
    await prefetchSenderKeys([PEER]);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("after a prefetch, decrypting the whole thread adds NO further request", async () => {
    const rows = await sealedThread(12);

    await prefetchSenderKeys(rows.map((r) => r.sender_user_id));
    expect(fetchImpl).toHaveBeenCalledTimes(1);

    const outcomes = await Promise.all(rows.map((r) => decryptMessage(r)));
    expect(outcomes.every((o) => o.ok)).toBe(true);
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });
});

describe("rotation invalidation — the correctness pin for the cached send path", () => {
  it("a ROTATED key is refetched after invalidateKeyCaches, and the new key verifies", async () => {
    const sodium = await sodiumReady();

    // Warm the cache with the peer's CURRENT key.
    await prefetchSenderKeys([PEER]);
    expect(fetchImpl).toHaveBeenCalledTimes(1);

    // The peer rotates: the registry now holds a different signing key.
    const rotated = sodium.crypto_sign_keypair();
    registryDevices.mockResolvedValue(await peerRegistry(rotated.publicKey, peerBox.publicKey));

    // The "Security code changed" pill is what the page feeds to this.
    invalidateKeyCaches();

    const sealed = await sealFrame(textFrame("after rotation"), rotated.privateKey, "web-peer", [
      { device_id: identity.deviceId, x25519_public: await b64(identity.x25519Public) }
    ]);

    const outcome = await decryptMessage(row(sealed, "m-rotated"));

    expect(fetchImpl).toHaveBeenCalledTimes(2);
    expect(outcome).toMatchObject({ ok: true, kind: "text", body: "after rotation" });
  });

  it("WITHOUT invalidation a cached key is reused — which is why the pill must stay wired", async () => {
    await prefetchSenderKeys([PEER]);

    const sodium = await sodiumReady();
    const rotated = sodium.crypto_sign_keypair();
    registryDevices.mockResolvedValue(await peerRegistry(rotated.publicKey, peerBox.publicKey));

    // No invalidation: the cache still holds the OLD key, so a message signed with the NEW one
    // fails its signature check — and the forced refetch is what repairs it.
    const sealed = await sealFrame(textFrame("rotated, uninvalidated"), rotated.privateKey, "web-peer", [
      { device_id: identity.deviceId, x25519_public: await b64(identity.x25519Public) }
    ]);

    const outcome = await decryptMessage(row(sealed, "m-stale"));

    // decryptMessage's own one-shot forced refetch on bad_sig rescues this case.
    expect(fetchImpl.mock.calls.length).toBeGreaterThanOrEqual(2);
    expect(outcome).toMatchObject({ ok: true, body: "rotated, uninvalidated" });
  });

  it("after a rotation the SEND seals to the NEW key — the recipient can open it", async () => {
    const sodium = await sodiumReady();

    // Warm the cache with the peer's CURRENT keys (what a chat open does).
    await prefetchSenderKeys([PEER]);
    expect(fetchImpl).toHaveBeenCalledTimes(1);

    // The peer rotates its AGREEMENT key. Nothing about a send can detect this: seal to the stale
    // key and the message is simply unreadable forever — no error, no stub, no retry. That silence
    // is why the send path may only read a cache that a rotation invalidates.
    const rotatedBox = sodium.crypto_box_keypair();
    registryDevices.mockResolvedValue(await peerRegistry(peerSign.publicKey, rotatedBox.publicKey));

    // The "Security code changed" pill, as the page applies it.
    invalidateKeyCaches();

    await sendSecretText({
      conversationId: CONV,
      memberIds: [PEER],
      senderUserId: "11111111-1111-4111-8111-111111111111",
      body: "sealed after the rotation"
    });

    expect(sealedSends).toHaveLength(1);
    const envelope = sealedSends[0].sealed.recipients.find((r) => r.device_id === "web-peer");
    expect(envelope).toBeTruthy();

    // THE ASSERTION: the peer's NEW private key opens it. Sealed to the stale key, this throws.
    const opened = sodium.crypto_box_seal_open(
      sodium.from_base64(envelope!.envelope_b64, sodium.base64_variants.ORIGINAL),
      rotatedBox.publicKey,
      rotatedBox.privateKey
    );
    expect(new TextDecoder().decode(opened)).toContain("sealed after the rotation");
  });

  it("invalidating ONE user leaves the others cached", async () => {
    const other = "44444444-4444-4444-8444-444444444444";
    await prefetchSenderKeys([PEER, other]);
    expect(fetchImpl).toHaveBeenCalledTimes(1);

    invalidateKeyCaches(PEER);

    await prefetchSenderKeys([other]);
    expect(fetchImpl).toHaveBeenCalledTimes(1);

    await prefetchSenderKeys([PEER]);
    expect(fetchImpl).toHaveBeenCalledTimes(2);
    expect(fetchCalls[1]).toEqual([PEER]);
  });
});
