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

/** Load this device's identity, generating + persisting it on first use. Idempotent + cached. */
export async function loadOrCreateIdentity(): Promise<DeviceIdentity> {
  if (cached) return cached;

  const sodium = await sodiumReady();
  const deviceId = getOrCreateDeviceId();
  const db = await openDb();

  const stored = await idbGet<StoredIdentity>(db, KEY);
  if (stored && stored.deviceId === deviceId) {
    cached = stored;
    return stored;
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
  cached = identity;
  return identity;
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
