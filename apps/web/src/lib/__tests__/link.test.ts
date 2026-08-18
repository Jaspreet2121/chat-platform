import { describe, expect, it, vi } from "vitest";

import { pollUntilResolved, type LinkWaitResult } from "../link";

// The QR-link poll loop (backend 1fb5f13): pending re-polls, approved resolves ONCE with the
// session, consumed/expired ask for a fresh code, abort resolves quietly to cancelled, and a
// network error backs off 2s→10s without giving up.

const session = {
  access_token: "at",
  refresh_token: "rt",
  expires_at: "2026-08-25T00:00:00Z",
  session_id: "sess-1"
};

function waitSequence(results: Array<LinkWaitResult | Error>) {
  let call = 0;

  const wait = vi.fn(async () => {
    const next = results[Math.min(call, results.length - 1)];
    call += 1;
    if (next instanceof Error) throw next;
    return next;
  });

  return wait;
}

const instantSleep = vi.fn(async () => {});

describe("pollUntilResolved", () => {
  it("pending → approved resolves with the session", async () => {
    const wait = waitSequence([
      { state: "pending" },
      { state: "pending" },
      { state: "approved", session }
    ]);

    const outcome = await pollUntilResolved("link-1", "pt", new AbortController().signal, {
      wait,
      sleep: instantSleep
    });

    expect(outcome).toEqual({ status: "approved", session });
    expect(wait).toHaveBeenCalledTimes(3);
  });

  it("consumed and expired each resolve to refresh (mint a new code)", async () => {
    for (const state of ["consumed", "expired"] as const) {
      const outcome = await pollUntilResolved(
        "link-1",
        "pt",
        new AbortController().signal,
        { wait: waitSequence([{ state }]), sleep: instantSleep }
      );

      expect(outcome).toEqual({ status: "refresh" });
    }
  });

  it("an aborted poll resolves to cancelled — before the first request and mid-flight", async () => {
    const aborted = new AbortController();
    aborted.abort();

    expect(
      await pollUntilResolved("link-1", "pt", aborted.signal, {
        wait: waitSequence([{ state: "pending" }]),
        sleep: instantSleep
      })
    ).toEqual({ status: "cancelled" });

    // Mid-flight: the wait rejects (fetch abort) AFTER the signal aborted → cancelled, not a retry.
    const controller = new AbortController();

    const wait = vi.fn(async () => {
      controller.abort();
      throw new Error("aborted");
    });

    expect(
      await pollUntilResolved("link-1", "pt", controller.signal, { wait, sleep: instantSleep })
    ).toEqual({ status: "cancelled" });
    expect(wait).toHaveBeenCalledTimes(1);
  });

  it("network errors back off 2s → 4s → 8s → 10s cap, then still deliver the approval", async () => {
    const sleeps: number[] = [];

    const sleep = vi.fn(async (ms: number) => {
      sleeps.push(ms);
    });

    const wait = waitSequence([
      new Error("net"),
      new Error("net"),
      new Error("net"),
      new Error("net"),
      { state: "approved", session }
    ]);

    const outcome = await pollUntilResolved("link-1", "pt", new AbortController().signal, {
      wait,
      sleep
    });

    expect(outcome).toEqual({ status: "approved", session });
    expect(sleeps).toEqual([2_000, 4_000, 8_000, 10_000]);
  });

  it("a successful poll resets the backoff", async () => {
    const sleeps: number[] = [];

    const sleep = vi.fn(async (ms: number) => {
      sleeps.push(ms);
    });

    const wait = waitSequence([
      new Error("net"),
      new Error("net"),
      { state: "pending" },
      new Error("net"),
      { state: "approved", session }
    ]);

    await pollUntilResolved("link-1", "pt", new AbortController().signal, { wait, sleep });

    // 2s, 4s, then the pending success resets → the next error starts at 2s again.
    expect(sleeps).toEqual([2_000, 4_000, 2_000]);
  });

  it("approved without a session body is NOT treated as approved (falls through to re-poll)", async () => {
    const wait = waitSequence([
      { state: "approved" } as LinkWaitResult,
      { state: "consumed" }
    ]);

    const outcome = await pollUntilResolved("link-1", "pt", new AbortController().signal, {
      wait,
      sleep: instantSleep
    });

    expect(outcome).toEqual({ status: "refresh" });
  });
});
