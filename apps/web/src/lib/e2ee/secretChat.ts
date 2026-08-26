// The web app's E2EE orchestration (108) — the bridge between the transport-agnostic frame
// (frame.ts) and the app's send/receive. Holds an in-memory decrypt LRU (no plaintext in
// IndexedDB in v1: a reload re-decrypts from the stored ciphertext — the tradeoff is a little CPU
// on load in exchange for no at-rest plaintext; recorded in E2EE_FRAME.md).

import {
  enableEncryption,
  fetchClientConfig,
  fetchUserKeys,
  getSealedMediaDownloadUrl,
  sendSealedMessage,
  uploadDeviceKeys,
  type DeviceKey,
  type Message
} from "@/lib/api";
import { uploadMediaBlob } from "@/lib/upload";
import { canonicalString, type FrameCleartext, type MediaDescriptor } from "@/lib/e2ee/canonical";
import { loadOrCreateIdentity, publicKeysBase64 } from "@/lib/e2ee/identity";
import { openFrame, sealFrame, type SealedPayload } from "@/lib/e2ee/frame";
import { openFile, sealFile } from "@/lib/e2ee/mediaCrypto";

// device_id → its registry keys, refreshed per send/receive (small; not persisted).
type KeyCache = Map<string, DeviceKey>;

const decryptLru = new Map<string, DecryptOutcome>();
const LRU_MAX = 500;

export type DecryptOutcome =
  | { ok: true; kind: "text"; body: string; senderDeviceId: string }
  | { ok: true; kind: "media"; media: MediaDescriptor; senderDeviceId: string }
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
  rememberDecrypt(message.message_id, {
    ok: true,
    kind: "text",
    body: input.body,
    senderDeviceId: identity.deviceId
  });
  return message;
}

/**
 * Send an encrypted attachment (E2EE_FRAME.md §media): encrypt the file client-side, upload the
 * CIPHERTEXT (purpose sealed_media, tied to the conversation), then seal a media frame carrying the
 * file key + integrity hash for every member device. `onStage` reports encrypting → uploading →
 * sent; a rejected upload never seals a message (the uploadMediaBlob invariant).
 */
export async function sendSecretMedia(input: {
  conversationId: string;
  memberIds: string[];
  senderUserId: string;
  file: File;
  thumb?: { bytes: Uint8Array; w: number; h: number };
  onStage?: (stage: "encrypting" | "uploading" | "sent") => void;
}): Promise<Message> {
  const identity = await loadOrCreateIdentity();
  const keys = await memberDeviceKeys(input.memberIds);

  input.onStage?.("encrypting");
  const plaintext = new Uint8Array(await input.file.arrayBuffer());
  const { ciphertext, descriptor } = await sealFile(
    { bytes: plaintext, mime: input.file.type || "application/octet-stream", name: input.file.name },
    input.thumb
  );

  input.onStage?.("uploading");
  const uploaded = await uploadMediaBlob({
    blob: new Blob([ciphertext], { type: "application/octet-stream" }),
    filename: `${input.file.name}.enc`,
    contentType: "application/octet-stream",
    purpose: "sealed_media",
    conversationId: input.conversationId,
    uploadErrorMessage: (code) => `Attachment upload failed (${code}).`
  });

  const media: MediaDescriptor = { ...descriptor, media_id: uploaded.mediaId };

  const clientMsgId = crypto.randomUUID();
  const composedAt = new Date().toISOString();
  const frame: FrameCleartext = {
    v: 1,
    sender_user_id: input.senderUserId,
    sender_device_id: identity.deviceId,
    conversation_id: input.conversationId,
    client_msg_id: clientMsgId,
    composed_at: composedAt,
    message_type: "media",
    body: "",
    media
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

  rememberDecrypt(message.message_id, {
    ok: true,
    kind: "media",
    media,
    senderDeviceId: identity.deviceId
  });
  input.onStage?.("sent");
  return message;
}

// media_id → the decrypted plaintext bytes, cached (small LRU; objectURLs are made by the UI and
// revoked on unmount). Download → sha256 verify → secretstream decrypt.
const fileLru = new Map<string, Uint8Array>();

export type FileFetchResult =
  | { ok: true; bytes: Uint8Array }
  | { ok: false; reason: "fetch_failed" | "hash_mismatch" | "decrypt_failed" };

export async function fetchSecretFile(media: MediaDescriptor): Promise<FileFetchResult> {
  const cached = fileLru.get(media.media_id);
  if (cached) return { ok: true, bytes: cached };

  let ciphertext: Uint8Array;
  try {
    const { download_url } = await getSealedMediaDownloadUrl(media.media_id);
    const response = await fetch(download_url);
    if (!response.ok) return { ok: false, reason: "fetch_failed" };
    ciphertext = new Uint8Array(await response.arrayBuffer());
  } catch {
    return { ok: false, reason: "fetch_failed" };
  }

  const opened = await openFile(ciphertext, media);
  if (!opened.ok) return opened;

  fileLru.set(media.media_id, opened.bytes);
  if (fileLru.size > 100) {
    const oldest = fileLru.keys().next().value;
    if (oldest) fileLru.delete(oldest);
  }
  return { ok: true, bytes: opened.bytes };
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
  if (!result.ok) return { ok: false, reason: result.reason };
  const frame = result.frame;
  if (frame.message_type === "media") {
    return { ok: true, kind: "media", media: frame.media, senderDeviceId };
  }
  return { ok: true, kind: "text", body: frame.body, senderDeviceId };
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

// ---- opportunistic upgrade (§9) ------------------------------------------------------------------

let clientConfigCache: { e2ee_default: boolean } | null = null;
const upgradeAttempted = new Set<string>();

/** client-config, fetched once per session (the server also sets Cache-Control: max-age=300). */
export async function e2eeDefault(): Promise<boolean> {
  if (clientConfigCache) return clientConfigCache.e2ee_default;
  try {
    clientConfigCache = await fetchClientConfig();
  } catch {
    clientConfigCache = { e2ee_default: false };
  }
  return clientConfigCache.e2ee_default;
}

/**
 * §upgrade trigger (ii): on OPENING a non-secret 1:1 in an e2ee_default app, if the peer has ≥1
 * device key, silently enable encryption (idempotent; the system pill + lock UI arrive via
 * realtime). Keyless peer → stay plaintext, no UI noise. At most one attempt per conversation per
 * session; best-effort (never blocks). Returns true if an enable call was made and succeeded.
 */
export async function maybeUpgradeConversation(input: {
  conversationId: string;
  peerUserId: string;
  isDirect: boolean;
  alreadySecret: boolean;
}): Promise<boolean> {
  if (input.alreadySecret || !input.isDirect) return false;
  if (upgradeAttempted.has(input.conversationId)) return false;
  upgradeAttempted.add(input.conversationId);

  try {
    if (!(await e2eeDefault())) return false;
    await registerDeviceKeys();

    const users = await fetchUserKeys([input.peerUserId]);
    const peerHasKeys = users.some(
      (u) => u.user_id === input.peerUserId && (u.devices?.length ?? 0) > 0
    );
    if (!peerHasKeys) return false;

    await enableEncryption(input.conversationId);
    return true;
  } catch {
    // peer_keys_missing / any error → stay plaintext, silent.
    return false;
  }
}

// Test seam.
export function __resetUpgradeState() {
  clientConfigCache = null;
  upgradeAttempted.clear();
}
