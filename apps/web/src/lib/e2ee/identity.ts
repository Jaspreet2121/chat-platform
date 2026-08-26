// This browser's E2EE identity (108). One Ed25519 signing keypair + one X25519 agreement keypair,
// generated on first use and PERSISTED IN INDEXEDDB. Why not WebCrypto non-extractable keys:
// WebCrypto has no Ed25519/X25519 across the browsers we support today, so we hold libsodium's raw
// private bytes — which means they ARE extractable from IndexedDB by definition. That is the honest
// v1 tradeoff (documented in E2EE_FRAME.md): the keys never leave the device and never touch the
// network in private form, but they are not hardware-sealed. Bound to the localStorage device_id
// (device.ts) so this identity is exactly the registered device.

import { getOrCreateDeviceId } from "@/lib/device";
import { sodiumReady } from "@/lib/e2ee/sodium";

const DB_NAME = "skifi-e2ee";
const STORE = "identity";
const KEY = "device-identity";

export type DeviceIdentity = {
  deviceId: string;
  ed25519Public: Uint8Array;
  ed25519Private: Uint8Array;
  x25519Public: Uint8Array;
  x25519Private: Uint8Array;
};

let cached: DeviceIdentity | null = null;
// In-flight guard. WITHOUT this, two concurrent callers in the SAME tab (login fires
// registerDeviceKeys while the first decrypt calls loadOrCreateIdentity) both see an empty store,
// both generate a keypair, and both write — last put wins while the loser keeps a DIFFERENT key in
// memory. The registry then holds a key this tab cannot decrypt with, so EVERY envelope addressed to
// this device fails to open, including the user's own messages.
let inFlight: Promise<DeviceIdentity> | null = null;

const LOCK_NAME = "skifi-e2ee-identity";

/** True when this browser can serialise across TABS, not just within one. */
function hasWebLocks(): boolean {
  return typeof navigator !== "undefined" && typeof navigator.locks?.request === "function";
}

/**
 * Run `work` under a cross-tab exclusive lock when the browser has the Web Locks API. Two tabs on a
 * first login otherwise race exactly as described above, except the loser's key is unrecoverable
 * because the winner's upload ROTATED the registry (that is a "Security code changed" pill).
 * Safari 16+/Chrome/Firefox all have Web Locks; without it we still hold the in-tab guard.
 */
async function withIdentityLock<T>(work: () => Promise<T>): Promise<T> {
  if (!hasWebLocks()) return work();
  return (await navigator.locks.request(LOCK_NAME, work)) as T;
}

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, 1);
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains(STORE)) {
        request.result.createObjectStore(STORE);
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

function idbGet<T>(db: IDBDatabase, key: string): Promise<T | undefined> {
  return new Promise((resolve, reject) => {
    const request = db.transaction(STORE, "readonly").objectStore(STORE).get(key);
    request.onsuccess = () => resolve(request.result as T | undefined);
    request.onerror = () => reject(request.error);
  });
}

function idbPut(db: IDBDatabase, key: string, value: unknown): Promise<void> {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, "readwrite");
    tx.objectStore(STORE).put(value, key);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

type StoredIdentity = {
  deviceId: string;
  ed25519Public: Uint8Array;
  ed25519Private: Uint8Array;
  x25519Public: Uint8Array;
  x25519Private: Uint8Array;
};

/**
 * Load this device's identity, generating + persisting it on first use.
 *
 * SINGLE-FLIGHT, by construction: exactly one keypair is ever generated per browser profile. The
 * in-memory promise collapses concurrent callers in this tab; the Web Locks request serialises
 * across tabs; and the store is re-read INSIDE the lock so a tab that loses the race adopts the
 * winner's key instead of minting a second one.
 */
export async function loadOrCreateIdentity(): Promise<DeviceIdentity> {
  if (cached) return cached;
  if (inFlight) return inFlight;

  inFlight = withIdentityLock(async () => {
    // Re-check under the lock: another tab may have generated + stored while we queued.
    if (cached) return cached;

    const sodium = await sodiumReady();
    const deviceId = getOrCreateDeviceId();
    const db = await openDb();

    const stored = await idbGet<StoredIdentity>(db, KEY);
    if (stored && stored.deviceId === deviceId) {
      cached = stored;
      return stored;
    }

    // SAFARI ITP / storage eviction: the device_id lives in localStorage and the keys in IndexedDB,
    // and Safari can evict IndexedDB while keeping localStorage. We then regenerate under the SAME
    // device_id, which rotates the registry — history sealed to the old key is unrecoverable. That
    // loss is unavoidable here; being silent about it is not.
    if (!stored && knownDeviceId(deviceId)) {
      console.warn(
        `[e2ee] identity store was empty for a KNOWN device_id (${deviceId}) — regenerating keys. ` +
          "Storage was likely evicted (Safari ITP); messages sealed to the old key can't be opened, " +
          "and this rotation shows as a 'Security code changed' notice."
      );
    }

    const sign = sodium.crypto_sign_keypair();
    const box = sodium.crypto_box_keypair();
    const identity: DeviceIdentity = {
      deviceId,
      ed25519Public: sign.publicKey,
      ed25519Private: sign.privateKey,
      x25519Public: box.publicKey,
      x25519Private: box.privateKey
    };

    await idbPut(db, KEY, identity);
    markDeviceIdSeen(deviceId);
    cached = identity;
    return identity;
  }).finally(() => {
    inFlight = null;
  });

  return inFlight;
}

// A marker written the first time we mint keys for a device_id. Its presence with an EMPTY identity
// store is the eviction signature (vs a genuinely first-ever run, which is silent and normal).
const SEEN_KEY = "skifi-e2ee-device-seen";

function knownDeviceId(deviceId: string): boolean {
  try {
    return window.localStorage.getItem(SEEN_KEY) === deviceId;
  } catch {
    return false;
  }
}

function markDeviceIdSeen(deviceId: string): void {
  try {
    window.localStorage.setItem(SEEN_KEY, deviceId);
  } catch {
    /* private mode / storage disabled — the warn simply won't fire next time. */
  }
}

/** base64 of the two PUBLIC keys, for the registry upload. */
export async function publicKeysBase64(): Promise<{ ed25519: string; x25519: string }> {
  const sodium = await sodiumReady();
  const identity = await loadOrCreateIdentity();
  return {
    ed25519: sodium.to_base64(identity.ed25519Public, sodium.base64_variants.ORIGINAL),
    x25519: sodium.to_base64(identity.x25519Public, sodium.base64_variants.ORIGINAL)
  };
}

// Test seam — reset the in-memory cache (never used in app code).
export function __resetIdentityCache() {
  cached = null;
}
