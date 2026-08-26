// Runs in the NODE environment (like the other e2ee suites): libsodium rejects the Uint8Array
// jsdom's TextEncoder produces, so a jsdom run fails inside crypto_sign_detached. Nothing here needs
// a DOM — the identity store is mocked and the File is a plain shim.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

/**
 * The two prod E2EE bugs.
 *
 * BUG 1 — a sealed message sent by A did not appear in B's OPEN chat, only after reopening.
 * `sendSealedMessage` is an HTTP POST, and the gateway's HTTP create path broadcasts ONLY the
 * conversation-list row: `message_created` on `conversation:<id>` is emitted exclusively by the
 * realtime channel's own create path. So nothing woke B's open thread. Plaintext never showed this
 * because it already sends over the socket. The fix routes sealed through the same channel, so these
 * tests pin (a) the transport seam, and (b) that a socket-delivered sealed row decrypts on arrival.
 *
 * BUG 2 — the sealed-media upload payload, locked to the media SERVICE's required attrs so it is
 * provable the web side is correct (see the report: the GATEWAY drops the purpose).
 */

const sendSealedMessage = vi.fn(async () => ({ message_id: "http-1" }));
type UploadCall = {
  blob: Blob;
  filename: string;
  contentType: string;
  purpose: string;
  conversationId: string;
};
const uploadMediaBlob = vi.fn<(input: UploadCall) => Promise<{ mediaId: string; objectKey: string }>>(
  async () => ({ mediaId: "m-1", objectKey: "k-1" })
);
// The key registry resolves every member to THIS device's real keys, so a sealed frame is genuinely
// sealed to a device we hold the private half of — that is what makes the round-trip below real.
const fetchUserKeysMock = vi.fn(async (ids: string[]) => {
  const { loadOrCreateIdentity } = await import("@/lib/e2ee/identity");
  const { sodiumReady } = await import("@/lib/e2ee/sodium");
  const sodium = await sodiumReady();
  const identity = await loadOrCreateIdentity();

  return ids.map((userId) => ({
    user_id: userId,
    devices: [
      {
        device_id: identity.deviceId,
        ed25519_public: sodium.to_base64(identity.ed25519Public, sodium.base64_variants.ORIGINAL),
        x25519_public: sodium.to_base64(identity.x25519Public, sodium.base64_variants.ORIGINAL)
      }
    ]
  }));
});
const createMediaUpload = vi.fn(async () => ({
  media_id: "m-1",
  object_key: "k-1",
  upload_url: "http://localhost:9000/put"
}));

vi.mock("@/lib/api", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/lib/api")>();
  return {
    ...actual,
    sendSealedMessage: (...a: unknown[]) => sendSealedMessage(...(a as [])),
    createMediaUpload: (...a: unknown[]) => createMediaUpload(...(a as [])),
    fetchUserKeys: (ids: string[]) => fetchUserKeysMock(ids),
    getSealedMediaDownloadUrl: vi.fn(),
    uploadDeviceKeys: vi.fn(async () => ({ saved: true })),
    enableEncryption: vi.fn(),
    fetchClientConfig: vi.fn(async () => ({ e2ee_default: true }))
  };
});

vi.mock("@/lib/upload", () => ({
  uploadMediaBlob: (input: UploadCall) => uploadMediaBlob(input)
}));

// The real identity store needs IndexedDB, which this environment has not. This stub holds ONE real
// libsodium identity for the whole file, which is what lets the seal → open round-trip below be
// genuine rather than a shape assertion.
vi.mock("@/lib/e2ee/identity", async () => {
  const { sodiumReady } = await import("@/lib/e2ee/sodium");
  const sodium = await sodiumReady();
  const sign = sodium.crypto_sign_keypair();
  const box = sodium.crypto_box_keypair();

  const identity = {
    deviceId: "web-test-device",
    ed25519Public: sign.publicKey,
    ed25519Private: sign.privateKey,
    x25519Public: box.publicKey,
    x25519Private: box.privateKey
  };

  return {
    loadOrCreateIdentity: async () => identity,
    publicKeysBase64: async () => ({
      ed25519: sodium.to_base64(sign.publicKey, sodium.base64_variants.ORIGINAL),
      x25519: sodium.to_base64(box.publicKey, sodium.base64_variants.ORIGINAL)
    })
  };
});

import { sealFrame } from "@/lib/e2ee/frame";
import { loadOrCreateIdentity } from "@/lib/e2ee/identity";
import { sodiumReady } from "@/lib/e2ee/sodium";
import {
  __clearCaches,
  decryptMessage,
  sendSecretMedia,
  sendSecretText,
  setSealedTransport
} from "@/lib/e2ee/secretChat";
import type { Message } from "@/lib/api";

type SealedSendCall = Parameters<Parameters<typeof setSealedTransport>[0] & object>[0];

const CONV = "33333333-3333-3333-3333-333333333333";
const ME = "11111111-1111-1111-1111-111111111111";

beforeEach(() => {
  __clearCaches();
  setSealedTransport(null);
  sendSealedMessage.mockClear();
  uploadMediaBlob.mockClear();
  createMediaUpload.mockClear();
});

afterEach(() => vi.clearAllMocks());

/** jsdom's File has no arrayBuffer(), so build the minimal shape sendSecretMedia actually reads. */
function testFile(bytes: Uint8Array, name: string, type: string): File {
  return {
    name,
    type,
    size: bytes.length,
    arrayBuffer: async () => bytes.buffer.slice(0) as ArrayBuffer
  } as unknown as File;
}

/** Build the message row the SERVER broadcasts for a sealed send (metadata.sealed is the frame). */
function serverRow(sealed: unknown, over: Partial<Message> = {}): Message {
  return {
    message_id: "srv-1",
    conversation_id: CONV,
    sender_user_id: ME,
    message_type: "sealed",
    body: null,
    metadata: { sealed },
    created_at: "2026-08-26T09:00:00.000Z",
    ...over
  } as unknown as Message;
}

describe("BUG 1 — sealed sends ride the socket, not HTTP", () => {
  it("uses the installed socket transport instead of the HTTP POST", async () => {
    const socketSend = vi.fn<(input: SealedSendCall) => Promise<Message>>(async () => serverRow({}, { message_id: "sock-1" }));
    setSealedTransport(socketSend);

    const message = await sendSecretText({
      conversationId: CONV,
      memberIds: [ME],
      senderUserId: ME,
      body: "hello over the socket"
    });

    // THE REGRESSION: this used to be the HTTP call, which the gateway never broadcasts from.
    expect(socketSend).toHaveBeenCalledTimes(1);
    expect(sendSealedMessage).not.toHaveBeenCalled();
    expect(message.message_id).toBe("sock-1");
  });

  it("the socket payload is the exact sealed shape — no media or body fields leak into it", async () => {
    const socketSend = vi.fn<(input: SealedSendCall) => Promise<Message>>(async () => serverRow({}, { message_id: "sock-2" }));
    setSealedTransport(socketSend);

    await sendSecretText({
      conversationId: CONV,
      memberIds: [ME],
      senderUserId: ME,
      body: "secret"
    });

    const sent = socketSend.mock.calls[0]?.[0] as unknown as Record<string, unknown>;
    expect(Object.keys(sent).sort()).toEqual(
      ["clientMsgId", "composedAt", "conversationId", "sealed"].sort()
    );
    // The plaintext must never ride the outer envelope.
    expect(JSON.stringify(sent.sealed)).not.toContain("secret");
  });

  it("falls back to HTTP when no channel is connected (the message still persists)", async () => {
    setSealedTransport(null);

    await sendSecretText({
      conversationId: CONV,
      memberIds: [ME],
      senderUserId: ME,
      body: "no channel"
    });

    expect(sendSealedMessage).toHaveBeenCalledTimes(1);
  });

  it("SENDER ECHO: my own sent message renders immediately, without a decrypt round-trip", async () => {
    const socketSend = vi.fn<(input: SealedSendCall) => Promise<Message>>(async () => serverRow({}, { message_id: "echo-1" }));
    setSealedTransport(socketSend);

    const message = await sendSecretText({
      conversationId: CONV,
      memberIds: [ME],
      senderUserId: ME,
      body: "my own words"
    });

    // The send primes the LRU, so the decrypt effect resolves the sender's own bubble instantly —
    // it never has to open a frame it wasn't a recipient of.
    const outcome = await decryptMessage(message);
    expect(outcome).toMatchObject({ ok: true, kind: "text", body: "my own words" });
  });
});

describe("BUG 1 — a socket-DELIVERED sealed row decrypts on arrival", () => {
  it("decrypts a row shaped exactly as the server broadcasts it (metadata.sealed)", async () => {
    // Seal a real frame TO this browser's own device, then hand it back the way the socket would.
    const sodium = await sodiumReady();
    const identity = await loadOrCreateIdentity();

    const sealed = await sealFrame(
      {
        v: 1,
        sender_user_id: ME,
        sender_device_id: identity.deviceId,
        conversation_id: CONV,
        client_msg_id: "cid-1",
        composed_at: "2026-08-26T09:00:00.000Z",
        message_type: "text",
        body: "arrived over the socket"
      },
      identity.ed25519Private,
      identity.deviceId,
      [
        {
          device_id: identity.deviceId,
          x25519_public: sodium.to_base64(identity.x25519Public, sodium.base64_variants.ORIGINAL)
        }
      ]
    );

    // No LRU priming: this is the RECIPIENT path, decrypting a row it never sent.
    __clearCaches();

    const outcome = await decryptMessage(serverRow(sealed, { message_id: "arrived-1" }));
    expect(outcome).toMatchObject({ ok: true, kind: "text", body: "arrived over the socket" });
  });

  it("a row whose metadata carries no sealed frame is a stub, never a crash", async () => {
    // Classified as no_frame since the reason codes landed — the row has no sealed payload at all,
    // which is a different (and differently-actionable) thing from a frame that failed to open.
    const outcome = await decryptMessage(serverRow(undefined, { message_id: "bad-1" }));
    expect(outcome).toEqual({ ok: false, reason: "no_frame" });
  });
});

describe("BUG 2 — the sealed-media upload payload", () => {
  it("uploads the CIPHERTEXT with purpose sealed_media and octet-stream, sized to the ciphertext", async () => {
    const socketSend = vi.fn<(input: SealedSendCall) => Promise<Message>>(async () => serverRow({}, { message_id: "media-1" }));
    setSealedTransport(socketSend);

    const plaintext = new Uint8Array(500).fill(7);
    const file = testFile(plaintext, "photo.jpg", "image/jpeg");

    await sendSecretMedia({
      conversationId: CONV,
      memberIds: [ME],
      senderUserId: ME,
      file
    });

    const call = uploadMediaBlob.mock.calls[0]?.[0] as UploadCall;

    // Locked to MediaService.Media's contract for this purpose: sealed_media REQUIRES
    // application/octet-stream (required_content_type/2), and the bytes are opaque ciphertext.
    expect(call.purpose).toBe("sealed_media");
    expect(call.contentType).toBe("application/octet-stream");
    expect(call.conversationId).toBe(CONV);
    expect(call.filename).toBe("photo.jpg.enc");

    // THE SIZE QUESTION: size_bytes is taken from this blob (upload.ts uses blob.size), and the SAME
    // blob is PUT — so the described size always equals the bytes stored. Ciphertext is longer than
    // the plaintext (per-chunk Poly1305 tags), which is exactly why the original file's size must
    // never be sent.
    expect(call.blob.size).toBeGreaterThan(plaintext.length);
  });

  it("the sealed message POST carries NO media_id or attachment fields — media rides INSIDE the frame", async () => {
    const socketSend = vi.fn<(input: SealedSendCall) => Promise<Message>>(async () => serverRow({}, { message_id: "media-2" }));
    setSealedTransport(socketSend);

    const file = testFile(new Uint8Array(64), "clip.mp4", "video/mp4");
    await sendSecretMedia({
      conversationId: CONV,
      memberIds: [ME],
      senderUserId: ME,
      file
    });

    const sent = socketSend.mock.calls[0]?.[0] as unknown as Record<string, unknown>;
    expect(Object.keys(sent).sort()).toEqual(
      ["clientMsgId", "composedAt", "conversationId", "sealed"].sort()
    );
    expect(sent).not.toHaveProperty("media_id");
    expect(sent).not.toHaveProperty("mediaId");
    expect(sent).not.toHaveProperty("caption");
    expect(sent).not.toHaveProperty("attachments");

    // The media descriptor (and the file key) live only inside the sealed envelope.
    expect(JSON.stringify(sent.sealed)).not.toContain("clip.mp4");
  });
});
