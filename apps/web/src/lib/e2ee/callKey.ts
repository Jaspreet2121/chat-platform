// E2EE calls (E2EE_FRAME.md §10). The caller mints a random 32-byte call key, seals it per device
// with crypto_box_seal — the SAME primitive, the SAME device-key registry, and the SAME browser
// identity as sealed messages (§3). There is never a second keypair: everything here goes through
// identity.ts.
//
// The server relays the sealed envelopes opaquely and carries two booleans; it cannot read the key.

import { fetchUserKeys, type DeviceKey } from "@/lib/api";
import { loadOrCreateIdentity } from "@/lib/e2ee/identity";
import { sodiumReady } from "@/lib/e2ee/sodium";

/** §10.1 — the call key is exactly 32 bytes (crypto_secretbox_KEYBYTES). */
export const CALL_KEY_BYTES = 32;

/** §10.2 caps, mirrored from the server's validator so we never build an offer it would refuse. */
export const MAX_ENVELOPES = 20;

export type CallEnvelope = { device_id: string; envelope_b64: string };

export type CallE2eeOffer = {
  v: 1;
  sender_device_id: string;
  envelopes: CallEnvelope[];
};

/** Distinct classes, logged like the message-decrypt classes so a broken call is diagnosable. */
export type CallKeyFailure =
  | "unsupported_browser"
  | "no_identity"
  | "no_offer"
  | "missing_envelope"
  | "open_failed"
  | "peer_keyless";

const TAG = "[call-e2ee]";

export function logCallE2ee(reason: CallKeyFailure, detail = ""): void {
  console.warn(`${TAG} ${reason}${detail ? ` ${detail}` : ""}`);
}

// ---- browser capability -------------------------------------------------------------------------

let supportCache: boolean | null = null;

/**
 * Can THIS browser do LiveKit frame encryption? It needs Insertable Streams (or the newer
 * ScriptTransform) plus Web Workers — Chrome/Edge have it, Safari does not as of writing.
 *
 * An unsupported browser behaves as a KEYLESS CLIENT for calls: it never offers and always accepts
 * plain, so calls still connect and simply run unencrypted with an honest indicator. Enabling E2EE
 * on one side only would publish encrypted frames a plain peer decodes as garbage audio.
 *
 * Logged ONCE per session — this is a fact about the browser, not a per-call event.
 */
export async function callE2eeSupported(): Promise<boolean> {
  if (supportCache !== null) return supportCache;

  try {
    const { isE2EESupported } = await import("livekit-client");
    supportCache = isE2EESupported();
  } catch {
    supportCache = false;
  }

  console.info(`${TAG} frame encryption ${supportCache ? "supported" : "NOT supported"} here`);
  return supportCache;
}

/** Test seam. */
export function __resetCallE2eeSupport(): void {
  supportCache = null;
}

// ---- key + envelopes ----------------------------------------------------------------------------

/** §10.1 — 32 cryptographically random bytes. Per call, never derived, never persisted. */
export async function generateCallKey(): Promise<Uint8Array> {
  const sodium = await sodiumReady();
  return sodium.randombytes_buf(CALL_KEY_BYTES);
}

/**
 * §10.2 — build the offer: seal the raw key once per recipient device.
 *
 * The recipient set is EVERY active device of the callee PLUS my own OTHER devices (the self-copy —
 * without it, answering on a second own device is impossible). My sending device is excluded: I hold
 * the key already, and every envelope spends part of the 32 KB budget.
 *
 * → null when there is nobody to seal to (a keyless callee): the caller then places an ordinary,
 * unencrypted call, which is exactly the pre-E2EE behaviour.
 */
export async function buildCallOffer(input: {
  callKey: Uint8Array;
  myUserId: string;
  calleeUserId: string;
}): Promise<CallE2eeOffer | null> {
  const sodium = await sodiumReady();
  const identity = await loadOrCreateIdentity();

  let users: Array<{ user_id: string; devices: DeviceKey[] }>;
  try {
    users = await fetchUserKeys([input.calleeUserId, input.myUserId]);
  } catch {
    logCallE2ee("peer_keyless", "key fetch failed");
    return null;
  }

  const calleeDevices = users.find((u) => u.user_id === input.calleeUserId)?.devices ?? [];
  if (calleeDevices.length === 0) {
    // Old or not-yet-keyed peer: no offer at all. The call proceeds plain with zero UI noise.
    logCallE2ee("peer_keyless", input.calleeUserId);
    return null;
  }

  const myOtherDevices = (users.find((u) => u.user_id === input.myUserId)?.devices ?? []).filter(
    (device) => device.device_id !== identity.deviceId
  );

  const recipients = [...calleeDevices, ...myOtherDevices].slice(0, MAX_ENVELOPES);

  const envelopes: CallEnvelope[] = recipients.map((device) => ({
    device_id: device.device_id,
    envelope_b64: sodium.to_base64(
      sodium.crypto_box_seal(
        input.callKey,
        sodium.from_base64(device.x25519_public, sodium.base64_variants.ORIGINAL)
      ),
      sodium.base64_variants.ORIGINAL
    )
  }));

  return { v: 1, sender_device_id: identity.deviceId, envelopes };
}

export type OpenCallKeyResult =
  | { ok: true; callKey: Uint8Array }
  | { ok: false; reason: CallKeyFailure };

/**
 * §10.3 — find MY device's envelope in an offer and open it. Any failure is a REASON, never a throw:
 * the caller answers with `e2ee_accepted: false` and the call proceeds unencrypted.
 */
export async function openCallKey(
  // Deliberately the LOOSE wire shape: this parses a server-relayed blob, so it must not assume the
  // literal `v: 1` its own builder produces.
  offer: { v?: number; sender_device_id?: string; envelopes?: CallEnvelope[] } | null
): Promise<OpenCallKeyResult> {
  if (!offer || !Array.isArray(offer.envelopes) || offer.envelopes.length === 0) {
    return { ok: false, reason: "no_offer" };
  }

  let identity: Awaited<ReturnType<typeof loadOrCreateIdentity>>;
  try {
    identity = await loadOrCreateIdentity();
  } catch {
    return { ok: false, reason: "no_identity" };
  }

  const mine = offer.envelopes.find((envelope) => envelope.device_id === identity.deviceId);
  if (!mine) return { ok: false, reason: "missing_envelope" };

  try {
    const sodium = await sodiumReady();
    const callKey = sodium.crypto_box_seal_open(
      sodium.from_base64(mine.envelope_b64, sodium.base64_variants.ORIGINAL),
      identity.x25519Public,
      identity.x25519Private
    );

    // A wrong-length key would silently produce a room nobody can decode — refuse it here instead.
    if (callKey.length !== CALL_KEY_BYTES) return { ok: false, reason: "open_failed" };
    return { ok: true, callKey };
  } catch {
    return { ok: false, reason: "open_failed" };
  }
}

// ---- feeding LiveKit ----------------------------------------------------------------------------

/**
 * §10.4 AMENDMENT — the raw-key → provider-key mapping, and why it is not the raw bytes.
 *
 * `ExternalE2EEKeyProvider.setKey()` takes `string | ArrayBuffer` and the two are NOT equivalent:
 *   * ArrayBuffer → HKDF, and livekit-client's own docs warn "Not all client SDKS support HKDF";
 *   * string      → PBKDF2, which it calls "recommended for maximum compatibility across SDKs".
 *
 * Since Android follows the same spec and must arrive at byte-identical key material, we take the
 * COMPATIBLE path: the 32-byte key is base64-encoded (RFC 4648 standard, padded — the same
 * convention as every other `_b64` field in this spec) and that STRING is passed to setKey().
 *
 * Both peers therefore run PBKDF2 over the identical ASCII string with the provider's default
 * options, which MUST NOT be overridden on either platform.
 */
export async function callKeyToProviderKey(callKey: Uint8Array): Promise<string> {
  const sodium = await sodiumReady();
  return sodium.to_base64(callKey, sodium.base64_variants.ORIGINAL);
}

/**
 * Best-effort zeroing of a call key when the call ends. The key lives in memory only — it is never
 * written to IndexedDB or localStorage — and overwriting the buffer removes it from any view still
 * holding a reference. (JS gives no guarantee the engine kept no copy; this is hygiene, not a
 * cryptographic erase, and it is why the key is per-call and short-lived in the first place.)
 */
export function wipeCallKey(callKey: Uint8Array | null | undefined): void {
  if (callKey && callKey.length > 0) callKey.fill(0);
}
