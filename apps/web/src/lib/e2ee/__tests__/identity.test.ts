// @vitest-environment jsdom
import "fake-indexeddb/auto";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { __resetIdentityCache, loadOrCreateIdentity, publicKeysBase64 } from "@/lib/e2ee/identity";

/**
 * Identity stability. The failure this pins is the one that broke production: TWO keypairs generated
 * for one browser profile. Whichever upload lands last owns the registry, so the tab holding the
 * other key cannot open ANY envelope addressed to its device — including its own sent messages,
 * because a sender seals to the REGISTRY's key, not to whatever that tab has in memory. Each extra
 * upload also shows up in the thread as a "Security code changed" pill.
 */

beforeEach(() => {
  __resetIdentityCache();
  window.localStorage.clear();
});

/** Empty the identity object store in place (see the note at the call site). */
function clearIdentityStore(): Promise<void> {
  return new Promise((resolve, reject) => {
    const open = indexedDB.open("skifi-e2ee", 1);
    open.onsuccess = () => {
      const db = open.result;
      const tx = db.transaction("identity", "readwrite");
      tx.objectStore("identity").clear();
      tx.oncomplete = () => {
        db.close();
        resolve();
      };
      tx.onerror = () => reject(tx.error);
    };
    open.onerror = () => reject(open.error);
  });
}

describe("single-flight identity init", () => {
  it("two CONCURRENT inits yield exactly ONE keypair", async () => {
    const [a, b] = await Promise.all([loadOrCreateIdentity(), loadOrCreateIdentity()]);

    // Same object, same bytes — not two keypairs that merely both got persisted.
    expect(a.deviceId).toBe(b.deviceId);
    expect(Array.from(a.x25519Private)).toEqual(Array.from(b.x25519Private));
    expect(Array.from(a.ed25519Private)).toEqual(Array.from(b.ed25519Private));
  });

  it("many concurrent inits still yield ONE keypair", async () => {
    const results = await Promise.all(Array.from({ length: 8 }, () => loadOrCreateIdentity()));
    const distinct = new Set(results.map((r) => r.x25519Public.join(",")));
    expect(distinct.size).toBe(1);
  });

  it("a LATER init (cold in-memory cache) reuses the persisted keypair, never a fresh one", async () => {
    const first = await loadOrCreateIdentity();

    // Simulate a reload: memory cleared, IndexedDB intact.
    __resetIdentityCache();
    const second = await loadOrCreateIdentity();

    expect(Array.from(second.x25519Private)).toEqual(Array.from(first.x25519Private));
  });

  it("the published public keys match the keypair actually held", async () => {
    const identity = await loadOrCreateIdentity();
    const published = await publicKeysBase64();
    const { sodiumReady } = await import("@/lib/e2ee/sodium");
    const sodium = await sodiumReady();

    expect(published.x25519).toBe(
      sodium.to_base64(identity.x25519Public, sodium.base64_variants.ORIGINAL)
    );
    expect(published.ed25519).toBe(
      sodium.to_base64(identity.ed25519Public, sodium.base64_variants.ORIGINAL)
    );
  });
});

describe("storage eviction (Safari ITP)", () => {
  it("warns when the key store is empty for a device_id we have minted keys for before", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);

    // First run: mints keys and records the device_id as seen. Silent — this is normal.
    await loadOrCreateIdentity();
    expect(warn).not.toHaveBeenCalled();

    // Now wipe the stored keys but KEEP localStorage — exactly what ITP eviction leaves behind.
    // (Clearing the store rather than deleting the database: the module holds an open connection,
    // which would block a deleteDatabase indefinitely.)
    await clearIdentityStore();
    __resetIdentityCache();

    await loadOrCreateIdentity();

    // History sealed to the old key is unrecoverable here; being silent about it is the bug.
    expect(warn).toHaveBeenCalled();
    expect(String(warn.mock.calls[0][0])).toContain("evicted");
    warn.mockRestore();
  });
});
