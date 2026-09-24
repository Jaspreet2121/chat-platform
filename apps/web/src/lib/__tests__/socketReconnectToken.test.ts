// @vitest-environment jsdom
//
// THE INTEGRATION PROOF for the 15-minute access token: a tab kept open past the TTL, then a forced
// socket reconnect, keeps working WITHOUT a reload.
//
// This drives the REAL `createSocket()` and `startTokenFreshness()` — not a re-implementation — with
// a short TTL (120 s, the value from the brief), a fake clock and a stubbed `/auth/refresh`. What it
// cannot do is run a real browser against a real gateway; the manual steps for that are in the
// report. What it DOES prove is the exact sequence that was broken: the params callback installed on
// the Socket returns the CURRENT token, and the freshness keeper rotates before expiry and wakes a
// socket that is down.
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const TTL_SECONDS = 120;

function storage() {
  const map = new Map<string, string>();
  return {
    getItem: (k: string) => map.get(k) ?? null,
    setItem: (k: string, v: string) => void map.set(k, v),
    removeItem: (k: string) => void map.delete(k),
    clear: () => map.clear(),
    key: () => null,
    length: 0
  } as unknown as Storage;
}

describe("a tab open past the access-token TTL survives a socket reconnect", () => {
  beforeEach(() => {
    vi.resetModules();
    Object.defineProperty(window, "localStorage", { value: storage(), configurable: true });
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-09-24T10:00:00.000Z"));
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it("the socket's params callback presents the ROTATED token after the first one expires", async () => {
    const { setSessionTokens, getAccessToken } = await import("../session");
    const { createSocket } = await import("../realtime");
    const { ensureFreshAccessToken } = await import("../api");

    // Login, with the shortened TTL.
    setSessionTokens({
      accessToken: "access-1",
      refreshToken: "refresh-1",
      accessTokenExpiresInSeconds: TTL_SECONDS
    });

    const socket = createSocket();
    // phoenix stores `params` as a closure; this is the callback it invokes on every (re)connect.
    const params = (socket as unknown as { params: () => Record<string, string> }).params;

    expect(params()).toEqual({ authorization: "Bearer access-1" });

    // The tab sits there past the TTL. Nothing has reconnected yet.
    vi.setSystemTime(new Date("2026-09-24T10:03:00.000Z")); // +180 s, token died at +120 s

    // Before the fix this is where it ended: the socket would reconnect with `access-1` forever.
    // Now the keeper's gate rotates first...
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => ({
        status: 200,
        json: async () => ({
          access_token: "access-2",
          refresh_token: "refresh-2",
          access_token_expires_in_seconds: TTL_SECONDS
        })
      }))
    );

    const result = await ensureFreshAccessToken();
    expect(result.status).toBe("refreshed");
    expect(getAccessToken()).toBe("access-2");

    // ...and the SAME socket object now presents the new token on its next connect. This is the
    // assertion the static-object version could never pass.
    expect(params()).toEqual({ authorization: "Bearer access-2" });
  });

  it("startTokenFreshness rotates before expiry and reconnects a socket that is down", async () => {
    const { setSessionTokens, getAccessToken } = await import("../session");
    const { startTokenFreshness } = await import("../realtime");

    setSessionTokens({
      accessToken: "access-1",
      refreshToken: "refresh-1",
      accessTokenExpiresInSeconds: TTL_SECONDS
    });

    const fetchMock = vi.fn(async () => ({
      status: 200,
      json: async () => ({
        access_token: "access-2",
        refresh_token: "refresh-2",
        access_token_expires_in_seconds: TTL_SECONDS
      })
    }));
    vi.stubGlobal("fetch", fetchMock);

    const connect = vi.fn();
    let connected = false;
    const socket = { isConnected: () => connected, connect } as never;

    // Mount: the token has 120 s left — outside the 60 s leeway, so nothing should happen.
    const stop = startTokenFreshness(socket);
    await vi.advanceTimersByTimeAsync(0);
    expect(fetchMock).not.toHaveBeenCalled();
    expect(connect).not.toHaveBeenCalled();

    // The tab stays open. At +90 s the token is inside the leeway; the next poll rotates it, and
    // because the socket is down it is woken — no reload, no user action.
    vi.setSystemTime(new Date("2026-09-24T10:01:30.000Z"));
    await vi.advanceTimersByTimeAsync(30_000);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(getAccessToken()).toBe("access-2");
    expect(connect).toHaveBeenCalledTimes(1);

    // A connected socket is never poked again, and a fresh token does no further network.
    connected = true;
    await vi.advanceTimersByTimeAsync(30_000);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(connect).toHaveBeenCalledTimes(1);

    stop();
    // After cleanup the timer is gone: no work, no leak.
    await vi.advanceTimersByTimeAsync(120_000);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
});
