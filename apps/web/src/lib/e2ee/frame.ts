// The sealed E2EE frame — transport-agnostic (108 / E2EE_FRAME.md). The SAME identity and frame
// serve the offline-messaging design later; nothing here knows about HTTP or sockets.
//
// alg string (stored on the wire, MUST equal the doc): "xsalsa20poly1305-sealedbox+ed25519".
//   * per-recipient-device box: libsodium crypto_box_seal (anonymous sealed box) to the recipient
//     device's X25519 public key — no nonce to manage, no sender key inside the box; the SENDER's
//     authenticity comes from the detached signature, not the box.
//   * signature: Ed25519 crypto_sign_detached over the canonical cleartext bytes (canonical.ts).
//     A recipient verifies the sig against the sender device's ED25519 key from the registry BEFORE
//     decrypting — a tampered or forged frame is rejected without ever opening a box.

import { canonicalBytes, type FrameCleartext } from "@/lib/e2ee/canonical";
import { sodiumReady } from "@/lib/e2ee/sodium";

export const FRAME_ALG = "xsalsa20poly1305-sealedbox+ed25519";

export type RecipientDeviceKey = {
  device_id: string;
  /** base64 X25519 public key. */
  x25519_public: string;
};

export type SealedRecipient = { device_id: string; envelope_b64: string };

export type SealedPayload = {
  v: 1;
  alg: string;
  sender_device_id: string;
  sig_b64: string;
  recipients: SealedRecipient[];
};

/**
 * Seal `frame` for every recipient device: sign the canonical bytes once (detached Ed25519), then
 * anonymous-sealed-box the SAME canonical bytes to each device's X25519 key. Returns the wire
 * `sealed` object. A recipient list is the union of BOTH members' active devices (incl. the
 * sender's own other devices, so they render their sent message too).
 */
export async function sealFrame(
  frame: FrameCleartext,
  ed25519PrivateKey: Uint8Array,
  senderDeviceId: string,
  recipients: RecipientDeviceKey[]
): Promise<SealedPayload> {
  const sodium = await sodiumReady();
  const bytes = canonicalBytes(frame);
  const sig = sodium.crypto_sign_detached(bytes, ed25519PrivateKey);

  const sealedRecipients = recipients.map((recipient) => {
    const pub = sodium.from_base64(recipient.x25519_public, sodium.base64_variants.ORIGINAL);
    const box = sodium.crypto_box_seal(bytes, pub);
    return {
      device_id: recipient.device_id,
      envelope_b64: sodium.to_base64(box, sodium.base64_variants.ORIGINAL)
    };
  });

  return {
    v: 1,
    alg: FRAME_ALG,
    sender_device_id: senderDeviceId,
    sig_b64: sodium.to_base64(sig, sodium.base64_variants.ORIGINAL),
    recipients: sealedRecipients
  };
}

export type OpenResult =
  | { ok: true; frame: FrameCleartext }
  | { ok: false; reason: "no_envelope" | "bad_sig" | "decrypt_failed" | "malformed" };

/**
 * Open a sealed payload for MY device: find my envelope, decrypt with my X25519 keypair, then
 * VERIFY the sender's detached signature over the decrypted canonical bytes against their ED25519
 * public key. Order matters — we decrypt first (only my key can), then authenticate. A missing
 * envelope (this device wasn't a recipient — e.g. sealed before it was linked) is `no_envelope`,
 * which the UI renders as the "not available on this device" stub, never a crash.
 */
export async function openFrame(
  sealed: SealedPayload,
  myDeviceId: string,
  myX25519PublicKey: Uint8Array,
  myX25519PrivateKey: Uint8Array,
  senderEd25519PublicB64: string | null
): Promise<OpenResult> {
  const sodium = await sodiumReady();

  const mine = sealed.recipients?.find((recipient) => recipient.device_id === myDeviceId);
  if (!mine) return { ok: false, reason: "no_envelope" };

  let plaintext: Uint8Array;
  try {
    const box = sodium.from_base64(mine.envelope_b64, sodium.base64_variants.ORIGINAL);
    plaintext = sodium.crypto_box_seal_open(box, myX25519PublicKey, myX25519PrivateKey);
  } catch {
    return { ok: false, reason: "decrypt_failed" };
  }

  if (!senderEd25519PublicB64) return { ok: false, reason: "bad_sig" };

  try {
    const sig = sodium.from_base64(sealed.sig_b64, sodium.base64_variants.ORIGINAL);
    const senderPub = sodium.from_base64(senderEd25519PublicB64, sodium.base64_variants.ORIGINAL);
    const valid = sodium.crypto_sign_verify_detached(sig, plaintext, senderPub);
    if (!valid) return { ok: false, reason: "bad_sig" };
  } catch {
    return { ok: false, reason: "bad_sig" };
  }

  try {
    const frame = JSON.parse(new TextDecoder().decode(plaintext)) as FrameCleartext;
    if (frame.v !== 1 || typeof frame.body !== "string") return { ok: false, reason: "malformed" };
    return { ok: true, frame };
  } catch {
    return { ok: false, reason: "malformed" };
  }
}
