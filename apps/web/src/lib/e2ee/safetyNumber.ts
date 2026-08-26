// Safety number (108 / E2EE_FRAME.md §4) — a display-only shared code both members compute
// identically to confirm no MITM. Deterministic and symmetric: sort the two devices'
// key_fingerprints (hex of sha256(ed25519_public)), join with ":", sha256, and read 60 DECIMAL
// digits (each source byte mod 10) as 12 groups of 5. Because the inputs are SORTED, both users
// derive the same number. SHA-256 via WebCrypto subtle.digest (present in browser + Node test env)
// — libsodium's standard build omits crypto_hash_sha256.
//
// v1 caveat (recorded in the doc): a fingerprint is per-DEVICE; the screen shows the primary pair.
// Multi-device safety numbers are a later refinement.

async function sha256(bytes: Uint8Array): Promise<Uint8Array> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return new Uint8Array(digest);
}

/** 60 decimal digits, 12 space-separated groups of 5, from the two sorted hex fingerprints. */
export async function safetyNumber(fingerprintA: string, fingerprintB: string): Promise<string> {
  const [lo, hi] = [fingerprintA, fingerprintB].sort();
  const combined = new TextEncoder().encode(`${lo}:${hi}`);

  // 32 bytes give 32 digits; hash the digest again to reach 60 — the fixed rule any reimplementation
  // follows.
  const first = await sha256(combined);
  const second = await sha256(first);
  const source = new Uint8Array(64);
  source.set(first, 0);
  source.set(second, 32);

  let digits = "";
  for (let i = 0; i < 60; i += 1) digits += (source[i] % 10).toString();

  return digits.match(/.{1,5}/g)!.join(" ");
}
