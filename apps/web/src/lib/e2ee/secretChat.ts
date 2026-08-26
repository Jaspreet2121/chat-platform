// The web app's E2EE orchestration (108) — the bridge between the transport-agnostic frame
// (frame.ts) and the app's send/receive. Holds an in-memory decrypt LRU (no plaintext in
// IndexedDB in v1: a reload re-decrypts from the stored ciphertext — the tradeoff is a little CPU
// on load in exchange for no at-rest plaintext; recorded in E2EE_FRAME.md).

import {
  enableEncryption,
  fetchUserKeys,
  sendSealedMessage,
  uploadDeviceKeys,
  type DeviceKey,
  type Message
} from "@/lib/api";
import { canonicalString, type FrameCleartext } from "@/lib/e2ee/canonical";
import { loadOrCreateIdentity, publicKeysBase64 } from "@/lib/e2ee/identity";
import { openFrame, sealFrame, type SealedPayload } from "@/lib/e2ee/frame";

// device_id → its registry keys, refreshed per send/receive (small; not persisted).
type KeyCache = Map<string, DeviceKey>;

const decryptLru = new Map<string, DecryptOutcome>();
const LRU_MAX = 500;

export type DecryptOutcome =
  | { ok: true; body: string; senderDeviceId: string }
  | { ok: false; reason: string };

/** Upload this browser's public keys with a small retry — key registration must not silently fail
 *  (a peer can't seal to us without it). */
export async function registerDeviceKeys(): Promise<void> {
  await loadOrCreateIdentity();
  const keys = await publicKeysBase64();

  let lastError: unknown;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      await uploadDeviceKeys({ ed25519_public: keys.ed25519, x25519_public: keys.x25519 });
      return;
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 300 * (attempt + 1)));
    }
  }
  throw lastError instanceof Error ? lastError : new Error("device key upload failed");
}

/** Turn on encryption for a 1:1 (server enforces the preconditions). */
export async function turnOnEncryption(conversationId: string): Promise<void> {
  await registerDeviceKeys();
  await enableEncryption(conversationId);
}

async function memberDeviceKeys(memberIds: string[]): Promise<KeyCache> {
  const users = await fetchUserKeys(memberIds);
  const cache: KeyCache = new Map();
  for (const user of users) {
    for (const device of user.devices) cache.set(device.device_id, device);
  }
  return cache;
}

/**
 * Seal a text body for every active device of the two members (incl. my own other devices) and
 * send it. Returns the created Message (already decryptable locally, cached below).
 */
export async function sendSecretText(input: {
  conversationId: string;
  memberIds: string[];
  senderUserId: string;
  body: string;
}): Promise<Message> {
  const identity = await loadOrCreateIdentity();
  const keys = await memberDeviceKeys(input.memberIds);

  const clientMsgId = crypto.randomUUID();
  const composedAt = new Date().toISOString();

  const frame: FrameCleartext = {
    v: 1,
    sender_user_id: input.senderUserId,
    sender_device_id: identity.deviceId,
    conversation_id: input.conversationId,
    client_msg_id: clientMsgId,
    composed_at: composedAt,
    message_type: "text",
    body: input.body
  };

  const recipients = Array.from(keys.values()).map((device) => ({
    device_id: device.device_id,
    x25519_public: device.x25519_public
  }));

  const sealed = await sealFrame(frame, identity.ed25519Private, identity.deviceId, recipients);

  const message = await sendSealedMessage({
    conversationId: input.conversationId,
    clientMsgId,
    composedAt,
    sealed
  });

  // Pre-fill the LRU so my own sent bubble renders instantly without a decrypt round-trip.
  rememberDecrypt(message.message_id, { ok: true, body: input.body, senderDeviceId: identity.deviceId });
  return message;
}

/**
 * Decrypt a received sealed message for rendering. Verifies the sender sig against the registry
 * key (refetches ONCE on a sig failure — the sender may have rotated). Cached in the LRU keyed by
 * message id. Never throws: an undecryptable message resolves to {ok:false} → the UI stub.
 */
export async function decryptMessage(message: Message): Promise<DecryptOutcome> {
  const cached = decryptLru.get(message.message_id);
  if (cached) return cached;

  const sealed = extractSealed(message);
  if (!sealed) return remember(message.message_id, { ok: false, reason: "malformed" });

  const identity = await loadOrCreateIdentity();
  const senderKey = await senderEd25519(message.sender_user_id, sealed.sender_device_id, false);

  const result = await openFrame(
    sealed,
    identity.deviceId,
    identity.x25519Public,
    identity.x25519Private,
    senderKey
  );

  if (!result.ok && result.reason === "bad_sig") {
    // Rotation: refetch the sender's current key ONCE and retry the verify.
    const refetched = await senderEd25519(message.sender_user_id, sealed.sender_device_id, true);
    const retry = await openFrame(
      sealed,
      identity.deviceId,
      identity.x25519Public,
      identity.x25519Private,
      refetched
    );
    return remember(message.message_id, toOutcome(retry, sealed.sender_device_id));
  }

  return remember(message.message_id, toOutcome(result, sealed.sender_device_id));
}

function toOutcome(
  result: Awaited<ReturnType<typeof openFrame>>,
  senderDeviceId: string
): DecryptOutcome {
  if (result.ok) return { ok: true, body: result.frame.body, senderDeviceId };
  return { ok: false, reason: result.reason };
}

function extractSealed(message: Message): SealedPayload | null {
  const sealed = (message.metadata as { sealed?: SealedPayload } | null)?.sealed;
  if (sealed && Array.isArray(sealed.recipients)) return sealed;
  return null;
}

// sender_user_id → device_id → ed25519 public (b64). Refetched on `force`.
const senderKeyCache = new Map<string, string>();

async function senderEd25519(
  userId: string,
  deviceId: string,
  force: boolean
): Promise<string | null> {
  const key = `${userId}:${deviceId}`;
  if (!force && senderKeyCache.has(key)) return senderKeyCache.get(key) ?? null;

  try {
    const users = await fetchUserKeys([userId]);
    for (const user of users) {
      for (const device of user.devices) {
        senderKeyCache.set(`${userId}:${device.device_id}`, device.ed25519_public);
      }
    }
  } catch {
    /* leave the cache as-is; a miss returns null → bad_sig stub */
  }

  return senderKeyCache.get(key) ?? null;
}

function rememberDecrypt(messageId: string, outcome: DecryptOutcome) {
  remember(messageId, outcome);
}

function remember(messageId: string, outcome: DecryptOutcome): DecryptOutcome {
  decryptLru.set(messageId, outcome);
  if (decryptLru.size > LRU_MAX) {
    const oldest = decryptLru.keys().next().value;
    if (oldest) decryptLru.delete(oldest);
  }
  return outcome;
}

// Test seams.
export const __canonicalString = canonicalString;
export function __clearCaches() {
  decryptLru.clear();
  senderKeyCache.clear();
}
