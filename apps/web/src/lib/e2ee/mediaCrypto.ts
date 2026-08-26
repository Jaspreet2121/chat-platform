// Encrypted-attachment crypto (E2EE_FRAME.md §8.2/§8.3) — client-side file encryption with
// libsodium crypto_secretstream_xchacha20poly1305, transport-agnostic like frame.ts. The plaintext
// file is encrypted into CIPHERTEXT (what gets uploaded); the 32-byte file key rides inside the
// sealed frame (so only member devices recover it). Integrity: sha256 of the ciphertext,
// authenticated by the frame signature.

import type { MediaDescriptor } from "@/lib/e2ee/canonical";
import { sodiumReady } from "@/lib/e2ee/sodium";

/** Default plaintext chunk size (§8.1 example). */
export const CHUNK_SIZE = 65536;
/** ≤8KB ciphertext for the inline thumbnail (§8.1). */
export const THUMB_MAX_CIPHERTEXT = 8192;

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/** Encrypt `plaintext` with a fresh key: chunked secretstream, FINAL tag on the last chunk. Returns
 *  the concatenated ciphertext, the header, and the file key (all raw bytes). */
export async function encryptFile(
  plaintext: Uint8Array,
  key: Uint8Array,
  chunkSize = CHUNK_SIZE
): Promise<{ ciphertext: Uint8Array; header: Uint8Array }> {
  const sodium = await sodiumReady();
  const { state, header } = sodium.crypto_secretstream_xchacha20poly1305_init_push(key);
  const TAG_MESSAGE = sodium.crypto_secretstream_xchacha20poly1305_TAG_MESSAGE;
  const TAG_FINAL = sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL;

  const parts: Uint8Array[] = [];
  // A zero-length file still emits ONE final chunk, so decrypt always sees a terminator.
  const total = plaintext.length;
  let offset = 0;
  do {
    const end = Math.min(offset + chunkSize, total);
    const chunk = plaintext.subarray(offset, end);
    const isFinal = end >= total;
    parts.push(
      sodium.crypto_secretstream_xchacha20poly1305_push(
        state,
        chunk,
        null,
        isFinal ? TAG_FINAL : TAG_MESSAGE
      )
    );
    offset = end;
  } while (offset < total);

  const ciphertext = concat(parts);
  return { ciphertext, header };
}

/** Decrypt ciphertext produced by encryptFile. Verifies the stream (Poly1305 per chunk) AND that
 *  the stream terminated with a FINAL tag — a truncated ciphertext is rejected. */
export async function decryptFile(
  ciphertext: Uint8Array,
  key: Uint8Array,
  header: Uint8Array,
  chunkSize = CHUNK_SIZE
): Promise<Uint8Array> {
  const sodium = await sodiumReady();
  const state = sodium.crypto_secretstream_xchacha20poly1305_init_pull(header, key);
  const TAG_FINAL = sodium.crypto_secretstream_xchacha20poly1305_TAG_FINAL;
  const ABYTES = sodium.crypto_secretstream_xchacha20poly1305_ABYTES;
  const encChunk = chunkSize + ABYTES;

  const parts: Uint8Array[] = [];
  let offset = 0;
  let sawFinal = false;
  while (offset < ciphertext.length) {
    const end = Math.min(offset + encChunk, ciphertext.length);
    const block = ciphertext.subarray(offset, end);
    const result = sodium.crypto_secretstream_xchacha20poly1305_pull(state, block, null);
    if (result === false) throw new Error("secretstream chunk failed");
    parts.push(result.message);
    if (result.tag === TAG_FINAL) {
      sawFinal = true;
      break;
    }
    offset = end;
  }

  if (!sawFinal) throw new Error("secretstream not terminated (truncated ciphertext)");
  return concat(parts);
}

/** Seal a plaintext file into the wire artefacts: the ciphertext to upload + the MediaDescriptor
 *  minus media_id (filled in by the caller after upload). An optional raw thumbnail is encrypted
 *  with the SAME file key into an inline ciphertext (dropped if it would exceed the ≤8KB cap). */
export async function sealFile(
  file: { bytes: Uint8Array; mime: string; name: string },
  thumb?: { bytes: Uint8Array; w: number; h: number }
): Promise<{
  ciphertext: Uint8Array;
  descriptor: Omit<MediaDescriptor, "media_id">;
}> {
  const sodium = await sodiumReady();
  const key = sodium.crypto_secretstream_xchacha20poly1305_keygen();
  const { ciphertext, header } = await encryptFile(file.bytes, key);

  let thumbField: MediaDescriptor["thumb"] | undefined;
  if (thumb) {
    // The thumb is its own secretstream (its own header), same key. Omit if the ciphertext blows
    // the ≤8KB inline cap — the receiver just shows a plain placeholder.
    const enc = await encryptFile(thumb.bytes, key);
    const inline = concat([enc.header, enc.ciphertext]);
    if (inline.length <= THUMB_MAX_CIPHERTEXT) {
      thumbField = {
        inline_b64: sodium.to_base64(inline, sodium.base64_variants.ORIGINAL),
        w: thumb.w,
        h: thumb.h
      };
    }
  }

  return {
    ciphertext,
    descriptor: {
      mime: file.mime,
      size: file.bytes.length,
      name: file.name,
      sha256_of_ciphertext: await sha256Hex(ciphertext),
      enc: {
        alg: "secretstream-xchacha20poly1305",
        header_b64: sodium.to_base64(header, sodium.base64_variants.ORIGINAL),
        chunk_size: CHUNK_SIZE
      },
      key_b64: sodium.to_base64(key, sodium.base64_variants.ORIGINAL),
      ...(thumbField ? { thumb: thumbField } : {})
    }
  };
}

export type OpenFileResult =
  | { ok: true; bytes: Uint8Array }
  | { ok: false; reason: "hash_mismatch" | "decrypt_failed" };

/** Verify + decrypt a downloaded ciphertext against a MediaDescriptor. */
export async function openFile(
  ciphertext: Uint8Array,
  descriptor: MediaDescriptor
): Promise<OpenFileResult> {
  if ((await sha256Hex(ciphertext)) !== descriptor.sha256_of_ciphertext) {
    return { ok: false, reason: "hash_mismatch" };
  }

  try {
    const sodium = await sodiumReady();
    const key = sodium.from_base64(descriptor.key_b64, sodium.base64_variants.ORIGINAL);
    const header = sodium.from_base64(descriptor.enc.header_b64, sodium.base64_variants.ORIGINAL);
    const bytes = await decryptFile(ciphertext, key, header, descriptor.enc.chunk_size);
    return { ok: true, bytes };
  } catch {
    return { ok: false, reason: "decrypt_failed" };
  }
}

/** Decrypt an inline thumbnail (same key as the file). null on any failure — the caller falls back
 *  to a plain placeholder, never crashes. */
export async function openThumb(descriptor: MediaDescriptor): Promise<Uint8Array | null> {
  if (!descriptor.thumb) return null;
  try {
    const sodium = await sodiumReady();
    const key = sodium.from_base64(descriptor.key_b64, sodium.base64_variants.ORIGINAL);
    const HEADERBYTES = sodium.crypto_secretstream_xchacha20poly1305_HEADERBYTES;
    // inline_b64 = header || ciphertext (the thumb's own stream).
    const blob = sodium.from_base64(descriptor.thumb.inline_b64, sodium.base64_variants.ORIGINAL);
    const header = blob.subarray(0, HEADERBYTES);
    const cipher = blob.subarray(HEADERBYTES);
    return await decryptFile(cipher, key, header, descriptor.enc.chunk_size);
  } catch {
    return null;
  }
}

function concat(parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}
