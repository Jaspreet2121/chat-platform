// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

/**
 * The connect path for E2EE calls, pinned against the two ways it broke in production.
 *
 * 1. ORDER. livekit-client's E2EEManager subscribes to the key provider's SetKey event inside the
 *    ROOM CONSTRUCTOR. A setKey() before the Room exists therefore fires with no listener and the key
 *    NEVER reaches the worker — the room runs encryption with no key. Proven by spying on
 *    worker.postMessage in Chrome: pre-Room setKey posts only `init`; post-Room setKey posts `init`
 *    AND `setKey`. These tests assert the call ORDER so it cannot silently regress.
 *
 * 2. DEGRADE. If any part of E2EE setup throws, the call must still CONNECT, unencrypted, with an
 *    honest indicator — never "Couldn't connect the call".
 */

const calls: string[] = [];

class FakeKeyProvider {
  constructor() {
    calls.push("provider:new");
  }
  async setKey(key: string) {
    calls.push(`provider:setKey(${typeof key})`);
  }
}

let roomCtorThrows = false;
let setE2EEEnabledThrows = false;

class FakeRoom {
  options: Record<string, unknown>;
  constructor(options: Record<string, unknown>) {
    this.options = options;
    calls.push(options.e2ee ? "room:new(e2ee)" : "room:new(plain)");
    if (roomCtorThrows && options.e2ee) throw new Error("device unsupported");
  }
  async setE2EEEnabled(enabled: boolean) {
    calls.push(`room:setE2EEEnabled(${enabled})`);
    if (setE2EEEnabledThrows) throw new Error("worker not ready");
  }
  async connect() {
    calls.push("room:connect");
  }
  on() {
    return this;
  }
  remoteParticipants = new Map();
  localParticipant = {
    setMicrophoneEnabled: async () => calls.push("mic:publish"),
    setCameraEnabled: async () => undefined
  };
  async disconnect() {}
}

// Minimal livekit surface — the real module needs a browser WebRTC stack.
vi.mock("livekit-client", () => ({
  Room: FakeRoom,
  ExternalE2EEKeyProvider: FakeKeyProvider,
  RoomEvent: new Proxy({}, { get: (_t, k) => String(k) }),
  DisconnectReason: {},
  Track: { Source: { Camera: "camera", Microphone: "microphone" } },
  VideoPresets: {
    h180: { resolution: {} },
    h360: { resolution: {} },
    h720: { resolution: {} }
  },
  isE2EESupported: () => true
}));

vi.mock("@/lib/api", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/lib/api")>();
  return {
    ...actual,
    createCallToken: async () => ({ url: "wss://sfu.test", token: "jwt" })
  };
});

import { connectToRoom } from "@/lib/calls";

const audioEl = () => ({ srcObject: null }) as unknown as HTMLMediaElement;

beforeEach(() => {
  calls.length = 0;
  roomCtorThrows = false;
  setE2EEEnabledThrows = false;
  vi.stubGlobal(
    "Worker",
    class {
      onerror: unknown = null;
      terminate() {
        calls.push("worker:terminate");
      }
      constructor() {
        calls.push("worker:new");
      }
    }
  );
  vi.spyOn(console, "info").mockImplementation(() => undefined);
  vi.spyOn(console, "error").mockImplementation(() => undefined);
  vi.spyOn(console, "warn").mockImplementation(() => undefined);
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("E2EE setup order (the production bug)", () => {
  it("keys the provider AFTER the Room and enables BEFORE connect", async () => {
    const conn = await connectToRoom("call-1", audioEl(), { e2eeProviderKey: "a".repeat(44) });

    expect(conn.encrypted).toBe(true);

    const order = calls.filter((c) => c !== "mic:publish");
    const room = order.indexOf("room:new(e2ee)");
    const setKey = order.findIndex((c) => c.startsWith("provider:setKey"));
    const enable = order.indexOf("room:setE2EEEnabled(true)");
    const connect = order.indexOf("room:connect");

    // THE REGRESSION: setKey before the Room means the manager isn't listening yet and the key is
    // silently dropped — the room then encrypts with no key.
    expect(setKey).toBeGreaterThan(room);
    // And encryption must be on before we ever connect/publish, so no plaintext frame escapes.
    expect(enable).toBeGreaterThan(setKey);
    expect(connect).toBeGreaterThan(enable);
  });

  it("passes the key as a STRING (the §10.4 PBKDF2 mapping, not an ArrayBuffer/HKDF)", async () => {
    await connectToRoom("call-1", audioEl(), { e2eeProviderKey: "a".repeat(44) });
    expect(calls).toContain("provider:setKey(string)");
  });

  it("a plain call builds a Room with NO e2ee options and never touches a worker", async () => {
    const conn = await connectToRoom("call-1", audioEl(), {});

    expect(conn.encrypted).toBe(false);
    expect(calls).toContain("room:new(plain)");
    expect(calls).not.toContain("worker:new");
    expect(calls.some((c) => c.startsWith("provider:"))).toBe(false);
  });
});

describe("degrade-to-plain guard", () => {
  it("E2EE setup THROWING still yields a CONNECTED, unencrypted call", async () => {
    setE2EEEnabledThrows = true;

    // The whole point: this must RESOLVE, not reject. A rejection here is what surfaced to the user
    // as "Couldn't connect the call".
    const conn = await connectToRoom("call-1", audioEl(), { e2eeProviderKey: "a".repeat(44) });

    expect(conn.encrypted).toBe(false);
    // It fell back to a plain Room and still connected.
    expect(calls).toContain("room:new(plain)");
    expect(calls).toContain("room:connect");
    // The dead worker is not left running.
    expect(calls).toContain("worker:terminate");
  });

  it("an unsupported browser (Room ctor throws on e2ee) also degrades to a connected plain call", async () => {
    roomCtorThrows = true;

    const conn = await connectToRoom("call-1", audioEl(), { e2eeProviderKey: "a".repeat(44) });

    expect(conn.encrypted).toBe(false);
    expect(calls).toContain("room:connect");
  });

  it("a Worker that cannot even be constructed degrades rather than failing the call", async () => {
    vi.stubGlobal(
      "Worker",
      class {
        constructor() {
          throw new Error("worker blocked");
        }
      }
    );

    const conn = await connectToRoom("call-1", audioEl(), { e2eeProviderKey: "a".repeat(44) });

    expect(conn.encrypted).toBe(false);
    expect(calls).toContain("room:connect");
  });
});
