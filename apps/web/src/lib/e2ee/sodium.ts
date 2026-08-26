// The libsodium-wasm handle. libsodium-wrappers (NOT -sumo): the standard build already carries
// every primitive this frame needs — crypto_sign_keypair/detached/verify_detached (Ed25519),
// crypto_box_keypair + crypto_box_seal/seal_open (X25519 anonymous sealed boxes), and base64. The
// sumo build is only needed for exotic primitives (argon2 variants, scalarmult edge cases); adding
// it would ~double the wasm payload for nothing.

import _sodium from "libsodium-wrappers";

let readyPromise: Promise<typeof _sodium> | null = null;

/** Resolve the initialised libsodium handle (idempotent — the wasm loads once per tab). */
export function sodiumReady(): Promise<typeof _sodium> {
  if (!readyPromise) {
    readyPromise = _sodium.ready.then(() => _sodium);
  }
  return readyPromise;
}

export type Sodium = typeof _sodium;
