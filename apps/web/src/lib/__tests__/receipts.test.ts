import { describe, expect, it, vi } from "vitest";
import type { Message } from "@/lib/api";
import {
  RECEIPT_BATCH_MAX,
  applyReceipt,
  chunkIds,
  claimUnreported,
  createDeliveredQueue,
  receiptFrameIds,
  reportInChunks
} from "@/lib/receipts";

function msg(id: string, sender: string, extra: Partial<Message> = {}): Message {
  return {
    conversation_id: "c1",
    message_id: id,
    sender_user_id: sender,
    message_type: "text",
    status: "sent",
    created_at: "2026-09-12T00:00:00Z",
    ...extra
  };
}

describe("claimUnreported — which messages get a receipt", () => {
  it("reports ONLY others' messages — never your own", () => {
    const rows = [msg("mine", "me"), msg("theirs", "peer"), msg("mine2", "me")];
    expect(claimUnreported(rows, "me", new Set())).toEqual(["theirs"]);
  });

  it("reports each message ONCE — a second pass over the same rows claims nothing", () => {
    const claimed = new Set<string>();
    const rows = [msg("a", "peer"), msg("b", "peer")];
    expect(claimUnreported(rows, "me", claimed)).toEqual(["a", "b"]);
    // Re-opening / re-rendering with the same rows: already claimed, so nothing re-reports.
    expect(claimUnreported(rows, "me", claimed)).toEqual([]);
    // A NEW arrival is still picked up.
    expect(claimUnreported([...rows, msg("c", "peer")], "me", claimed)).toEqual(["c"]);
  });
});

describe("reportInChunks — one push per chunk, chunked at the server cap", () => {
  it("a 50-message batch is ONE push, not fifty", async () => {
    const push = vi.fn().mockResolvedValue({ accepted: 50 });
    const ids = Array.from({ length: 50 }, (_, i) => `m${i}`);
    await reportInChunks(ids, new Set(ids), push);
    expect(push).toHaveBeenCalledTimes(1);
    expect(push.mock.calls[0][0]).toEqual(ids);
  });

  it("a 300-message backfill chunks into 3 pushes of 100 — the cap is real", async () => {
    expect(RECEIPT_BATCH_MAX).toBe(100);
    const push = vi.fn().mockResolvedValue({});
    const ids = Array.from({ length: 300 }, (_, i) => `m${i}`);
    await reportInChunks(ids, new Set(ids), push);
    expect(push).toHaveBeenCalledTimes(3);
    expect(push.mock.calls.map((c) => c[0].length)).toEqual([100, 100, 100]);
    expect(push.mock.calls.flatMap((c) => c[0])).toEqual(ids);
    // No chunk ever exceeds what the server accepts.
    expect(chunkIds(ids).every((c) => c.length <= RECEIPT_BATCH_MAX)).toBe(true);
  });

  it("a failed chunk is un-claimed so the next pass retries it; a successful one stays claimed", async () => {
    const push = vi.fn().mockRejectedValueOnce(new Error("down")).mockResolvedValue({});
    const ids = Array.from({ length: 150 }, (_, i) => `m${i}`);
    const claimed = new Set(ids);
    await reportInChunks(ids, claimed, push);
    expect(push).toHaveBeenCalledTimes(2);
    // First chunk (m0..m99) failed → released; second (m100..m149) succeeded → still claimed.
    expect(claimed.has("m0")).toBe(false);
    expect(claimed.has("m99")).toBe(false);
    expect(claimed.has("m100")).toBe(true);
  });
});

describe("receipt_updated — the frame contract (ONE frame for N)", () => {
  it("applies a batched frame to EVERY id in payload.message_ids", () => {
    const rows = [msg("a", "me"), msg("b", "me"), msg("c", "me"), msg("d", "me")];
    const next = applyReceipt(rows, {
      receipt_type: "delivered",
      payload: { message_ids: ["a", "b", "c"], message_id: "a" }
    });
    expect(next.map((m) => m.delivered_by_count ?? 0)).toEqual([1, 1, 1, 0]);
    expect(next.map((m) => m.read_by_count ?? 0)).toEqual([0, 0, 0, 0]);
  });

  it("a read frame bumps read AND delivered for all of them", () => {
    const rows = [msg("a", "me"), msg("b", "me")];
    const next = applyReceipt(rows, {
      receipt_type: "read",
      payload: { message_ids: ["a", "b"], message_id: "a" }
    });
    expect(next.map((m) => [m.delivered_by_count, m.read_by_count])).toEqual([
      [1, 1],
      [1, 1]
    ]);
  });

  it("still understands the single-message frame (message_id only)", () => {
    expect(receiptFrameIds({ payload: { message_id: "solo" } })).toEqual(["solo"]);
    expect(receiptFrameIds({ payload: { message_ids: ["x", "y"], message_id: "x" } })).toEqual([
      "x",
      "y"
    ]);
    expect(receiptFrameIds({ payload: {} })).toEqual([]);
    expect(receiptFrameIds(undefined)).toEqual([]);
  });

  it("never lowers a count the timeline already reported", () => {
    const rows = [msg("a", "me", { delivered_by_count: 3, read_by_count: 2 })];
    const next = applyReceipt(rows, { receipt_type: "delivered", payload: { message_id: "a" } });
    expect(next[0].delivered_by_count).toBe(3);
    expect(next[0].read_by_count).toBe(2);
  });
});

describe("createDeliveredQueue — delivered for threads that are NOT open", () => {
  it("coalesces a burst into ONE push per conversation, deduped for its lifetime", () => {
    vi.useFakeTimers();
    try {
      const push = vi.fn().mockResolvedValue({});
      const queue = createDeliveredQueue(push, 250);
      queue.enqueue("c1", "m1");
      queue.enqueue("c1", "m2");
      queue.enqueue("c2", "m9");
      queue.enqueue("c1", "m1"); // duplicate arrival (reconnect replay)
      expect(push).not.toHaveBeenCalled();

      vi.advanceTimersByTime(250);
      expect(push).toHaveBeenCalledTimes(2);
      expect(push).toHaveBeenCalledWith("c1", ["m1", "m2"]);
      expect(push).toHaveBeenCalledWith("c2", ["m9"]);

      // Already reported → never again.
      queue.enqueue("c1", "m2");
      vi.advanceTimersByTime(250);
      expect(push).toHaveBeenCalledTimes(2);
    } finally {
      vi.useRealTimers();
    }
  });

  it("chunks at the cap even on the user-topic path", () => {
    vi.useFakeTimers();
    try {
      const push = vi.fn().mockResolvedValue({});
      const queue = createDeliveredQueue(push, 10);
      for (let i = 0; i < 250; i++) queue.enqueue("c1", `m${i}`);
      vi.advanceTimersByTime(10);
      expect(push.mock.calls.map((c) => c[1].length)).toEqual([100, 100, 50]);
    } finally {
      vi.useRealTimers();
    }
  });
});
