// @vitest-environment jsdom
import { describe, expect, it, vi } from "vitest";
import { parseUpiPayload, upiPayLink } from "@/lib/upi";
import { joinUserChannel } from "@/lib/realtime";

/**
 * UPI payload reading (for the confirm-before-save step) and the profile_changed subscription. The
 * latter matters because the server generates the QR ASYNCHRONOUSLY after a payment PATCH — the URL
 * is absent from that PATCH's response, so a client that doesn't refetch on the event shows nothing
 * until a manual reload.
 */

describe("parseUpiPayload", () => {
  it("reads the payee id and name out of a scanned payload", () => {
    expect(parseUpiPayload("upi://pay?pa=shop@okaxis&pn=Sharma%20Stores&mc=5411")).toEqual({
      upiId: "shop@okaxis",
      payeeName: "Sharma Stores"
    });
  });

  it("accepts the scheme case-insensitively (real-world QRs do this)", () => {
    expect(parseUpiPayload("UPI://PAY?pa=a.b@bank")?.upiId).toBe("a.b@bank");
  });

  it("refuses anything that isn't a upi://pay link", () => {
    expect(parseUpiPayload("https://evil.example?pa=a.b@bank")).toBeNull();
    expect(parseUpiPayload("upi://collect?pa=a.b@bank")).toBeNull();
    expect(parseUpiPayload("not a url")).toBeNull();
  });

  it("refuses a missing or malformed payee address", () => {
    expect(parseUpiPayload("upi://pay?pn=NoVpa")).toBeNull();
    expect(parseUpiPayload("upi://pay?pa=has space@bank")).toBeNull();
    expect(parseUpiPayload("upi://pay?pa=x@123")).toBeNull();
  });

  it("does not surface merchant params — they ride the RAW payload to the server verbatim", () => {
    const parsed = parseUpiPayload("upi://pay?pa=shop@okaxis&mc=5411&tr=INV42&sign=aBc");
    expect(parsed).toEqual({ upiId: "shop@okaxis", payeeName: undefined });
  });
});

describe("upiPayLink", () => {
  it("builds a deep link with the payee, name and currency", () => {
    expect(upiPayLink("me@bank", "Me")).toBe("upi://pay?pa=me%40bank&pn=Me&cu=INR");
  });

  it("encodes spaces as %20, never '+' (strict PSP parsers reject '+')", () => {
    const link = upiPayLink("me@bank", "Sharma Stores");
    expect(link).toContain("pn=Sharma%20Stores");
    expect(link).not.toContain("+");
  });

  it("omits the name when there isn't one", () => {
    expect(upiPayLink("me@bank", null)).toBe("upi://pay?pa=me%40bank&cu=INR");
  });
});

describe("profile_changed subscription", () => {
  // A minimal Phoenix channel/socket double: enough to prove joinUserChannel wires the event name.
  function fakeSocket() {
    const handlers = new Map<string, (payload: unknown) => void>();
    const channel = {
      on: vi.fn((event: string, cb: (payload: unknown) => void) => {
        handlers.set(event, cb);
        return 1;
      }),
      off: vi.fn(),
      push: vi.fn(),
      leave: vi.fn(),
      join: vi.fn(() => {
        const chain = {
          receive: (status: string, cb: (arg?: unknown) => void) => {
            if (status === "ok") cb();
            return chain;
          }
        };
        return chain;
      })
    };

    return {
      socket: { isConnected: () => true, connect: vi.fn(), channel: () => channel },
      handlers
    };
  }

  it("subscribes to profile_changed and fires the callback when the server broadcasts", async () => {
    const { socket, handlers } = fakeSocket();

    // eslint-disable-next-line @typescript-eslint/no-explicit-any -- minimal Phoenix double
    const joined = await joinUserChannel(socket as any, "u1");

    const onChanged = vi.fn();
    joined.onProfileChanged(onChanged);

    expect(handlers.has("profile_changed")).toBe(true);

    // The payload carries nothing actionable, so the handler must fire regardless of its contents.
    handlers.get("profile_changed")?.({ type: "profile_changed" });
    expect(onChanged).toHaveBeenCalledTimes(1);
  });

  it("also wires the quick-replies and auto-replies refetch events", async () => {
    const { socket, handlers } = fakeSocket();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any -- minimal Phoenix double
    const joined = await joinUserChannel(socket as any, "u1");

    const onQuick = vi.fn();
    const onAuto = vi.fn();
    joined.onQuickRepliesChanged(onQuick);
    joined.onAutoRepliesChanged(onAuto);

    handlers.get("quick_replies_changed")?.({});
    handlers.get("auto_replies_changed")?.({});

    expect(onQuick).toHaveBeenCalledTimes(1);
    expect(onAuto).toHaveBeenCalledTimes(1);
  });
});
