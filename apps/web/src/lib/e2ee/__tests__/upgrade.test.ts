import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// Mock the API + identity so the upgrade decision is testable without network/IndexedDB.
const enableEncryption = vi.fn(async () => ({ enabled: true }));
const fetchClientConfig = vi.fn(async () => ({ e2ee_default: true }));
const fetchUserKeys = vi.fn(async (_ids: string[]) => [] as Array<{ user_id: string; devices: unknown[] }>);

vi.mock("@/lib/api", () => ({
  enableEncryption: (...a: unknown[]) => enableEncryption(...(a as [])),
  fetchClientConfig: () => fetchClientConfig(),
  fetchUserKeys: (ids: string[]) => fetchUserKeys(ids),
  getSealedMediaDownloadUrl: vi.fn(),
  sendSealedMessage: vi.fn(),
  uploadDeviceKeys: vi.fn(async () => ({ saved: true }))
}));

vi.mock("@/lib/upload", () => ({ uploadMediaBlob: vi.fn() }));

vi.mock("@/lib/e2ee/identity", () => ({
  loadOrCreateIdentity: vi.fn(async () => ({ deviceId: "web-me" })),
  publicKeysBase64: vi.fn(async () => ({ ed25519: "e", x25519: "x" }))
}));

import { __resetUpgradeState, maybeUpgradeConversation } from "@/lib/e2ee/secretChat";

const PEER = "22222222-2222-2222-2222-222222222222";
const CONV = "33333333-3333-3333-3333-333333333333";

beforeEach(() => {
  __resetUpgradeState();
  enableEncryption.mockClear();
  fetchClientConfig.mockClear();
  fetchUserKeys.mockClear();
  fetchClientConfig.mockResolvedValue({ e2ee_default: true });
  fetchUserKeys.mockResolvedValue([{ user_id: PEER, devices: [{ device_id: "web-peer" }] }]);
});

afterEach(() => vi.clearAllMocks());

const call = (over: Partial<Parameters<typeof maybeUpgradeConversation>[0]> = {}) =>
  maybeUpgradeConversation({
    conversationId: CONV,
    peerUserId: PEER,
    isDirect: true,
    alreadySecret: false,
    ...over
  });

describe("upgrade trigger matrix (§9 ii)", () => {
  it("default-on + peer has keys → enables (once); a second open does not re-call", async () => {
    expect(await call()).toBe(true);
    expect(enableEncryption).toHaveBeenCalledTimes(1);

    // Same conversation, same session → no second attempt.
    expect(await call()).toBe(false);
    expect(enableEncryption).toHaveBeenCalledTimes(1);
  });

  it("keyless peer → NO enable, stays plaintext, silent", async () => {
    fetchUserKeys.mockResolvedValue([{ user_id: PEER, devices: [] }]);
    expect(await call()).toBe(false);
    expect(enableEncryption).not.toHaveBeenCalled();
  });

  it("app NOT default-on → nothing happens", async () => {
    fetchClientConfig.mockResolvedValue({ e2ee_default: false });
    expect(await call()).toBe(false);
    expect(enableEncryption).not.toHaveBeenCalled();
  });

  it("already secret, or a group → never attempts", async () => {
    expect(await call({ alreadySecret: true })).toBe(false);
    expect(await call({ isDirect: false })).toBe(false);
    expect(enableEncryption).not.toHaveBeenCalled();
  });

  it("an enable error (e.g. peer_keys_missing race) is swallowed, not thrown", async () => {
    enableEncryption.mockRejectedValueOnce(new Error("secret.peer_keys_missing"));
    expect(await call()).toBe(false);
  });
});
