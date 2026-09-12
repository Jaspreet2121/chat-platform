import type { Message } from "./api";
import type { ReceiptPayload } from "./realtime";

/**
 * Batched receipts — ONE push, ONE limiter charge, N receipts.
 *
 * Opening a thread with 50 unread used to send 50 `message_read` pushes; adding delivered on that
 * shape would have doubled it. The server now takes `{ message_ids }` on `messages_read` /
 * `messages_delivered` (and, for a thread that is NOT open, `messages_delivered` on the user topic).
 *
 * Everything here is pure so the rules — batch, chunk, filter to others' messages, report once —
 * are pinned by tests without rendering the chat page.
 */

/**
 * THE CHUNK SIZE. Mirrors the server cap (`RealtimeGateway.Receipts.max_batch`) exactly: the server
 * REFUSES a larger batch rather than truncating it, so a client that chunked at a different number
 * would either lose receipts or make an extra round-trip. 100 keeps a frame ~4 KB and turns the worst
 * realistic backfill (a 300-message thread) into 3 pushes, not 300.
 */
export const RECEIPT_BATCH_MAX = 100;

export function chunkIds(ids: readonly string[], size = RECEIPT_BATCH_MAX): string[][] {
  const chunks: string[][] = [];
  for (let i = 0; i < ids.length; i += size) chunks.push(ids.slice(i, i + size));
  return chunks;
}

type Reportable = Pick<Message, "message_id" | "sender_user_id">;

/**
 * Pick the ids that still need reporting — OTHERS' messages not yet claimed — and claim them in
 * place. Claiming up front keeps a re-render from reporting the same message twice; a failed push
 * releases its ids (see reportInChunks) so the next pass retries them.
 */
export function claimUnreported(
  messages: readonly Reportable[],
  selfUserId: string,
  claimed: Set<string>
): string[] {
  const ids: string[] = [];
  for (const message of messages) {
    // Never report a receipt on your OWN message: the ticks are the sender's view of the recipient.
    if (message.sender_user_id === selfUserId) continue;
    if (claimed.has(message.message_id)) continue;
    claimed.add(message.message_id);
    ids.push(message.message_id);
  }
  return ids;
}

/** One push per chunk. A chunk that fails is un-claimed so a later pass can retry it. */
export async function reportInChunks(
  ids: readonly string[],
  claimed: Set<string>,
  push: (chunk: string[]) => Promise<unknown>
): Promise<void> {
  for (const chunk of chunkIds(ids)) {
    try {
      await push(chunk);
    } catch {
      for (const id of chunk) claimed.delete(id);
    }
  }
}

/**
 * The ids a `receipt_updated` frame applies to. A batched frame carries `message_ids` (all of them)
 * plus `message_id` (the first, for consumers that predate batching); a single-message frame carries
 * only `message_id`. Read the batch when present, else fall back — never both.
 */
export function receiptFrameIds(frame: ReceiptPayload | null | undefined): string[] {
  const payload = frame?.payload;
  if (!payload) return [];
  const batch = Array.isArray(payload.message_ids)
    ? payload.message_ids.filter((id): id is string => typeof id === "string" && id !== "")
    : [];
  if (batch.length > 0) return batch;
  return typeof payload.message_id === "string" && payload.message_id !== ""
    ? [payload.message_id]
    : [];
}

/**
 * Apply a receipt frame to EVERY message it names. A read implies delivered, so it bumps both;
 * delivered bumps only delivered. We track a count (≥1 = at least one other has read/received) —
 * exact for 1:1; the durable counts on the next timeline fetch are authoritative.
 */
export function applyReceipt(messages: Message[], frame: ReceiptPayload): Message[] {
  const ids = new Set(receiptFrameIds(frame));
  if (ids.size === 0) return messages;
  return messages.map((item) => {
    if (!ids.has(item.message_id)) return item;
    const delivered = Math.max(item.delivered_by_count ?? 0, 1);
    return frame.receipt_type === "read"
      ? { ...item, read_by_count: Math.max(item.read_by_count ?? 0, 1), delivered_by_count: delivered }
      : { ...item, delivered_by_count: delivered };
  });
}

export type DeliveredQueue = {
  /** Queue one arrival; flushed per conversation after `delayMs` so a burst becomes one push. */
  enqueue: (conversationId: string, messageId: string) => void;
  flush: () => void;
  dispose: () => void;
};

/**
 * Delivered for threads that are NOT open. Messages arrive on the user topic one at a time, so a
 * short window coalesces a burst into one `messages_delivered` per conversation (chunked at the cap).
 * Deduped for the queue's lifetime — the user channel lives as long as the tab — so a reconnect
 * replay never re-reports.
 */
export function createDeliveredQueue(
  push: (conversationId: string, messageIds: string[]) => Promise<unknown>,
  delayMs = 250
): DeliveredQueue {
  const pending = new Map<string, Set<string>>();
  const reported = new Set<string>();
  let timer: ReturnType<typeof setTimeout> | null = null;

  function flush() {
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
    const batches = [...pending.entries()];
    pending.clear();
    for (const [conversationId, ids] of batches) {
      for (const chunk of chunkIds([...ids])) {
        void push(conversationId, chunk).catch(() => {
          for (const id of chunk) reported.delete(`${conversationId}:${id}`);
        });
      }
    }
  }

  return {
    enqueue(conversationId, messageId) {
      const key = `${conversationId}:${messageId}`;
      if (reported.has(key)) return;
      reported.add(key);
      let ids = pending.get(conversationId);
      if (!ids) {
        ids = new Set();
        pending.set(conversationId, ids);
      }
      ids.add(messageId);
      if (!timer) timer = setTimeout(flush, delayMs);
    },
    flush,
    dispose() {
      if (timer) clearTimeout(timer);
      timer = null;
      pending.clear();
    }
  };
}
