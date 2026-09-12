import { useEffect, useRef } from "react";
import type { Message } from "@/lib/api";
import { claimUnreported, reportInChunks } from "@/lib/receipts";

export type ReceiptChannel = {
  markDeliveredBatch: (messageIds: string[]) => Promise<unknown>;
  markReadBatch: (messageIds: string[]) => Promise<unknown>;
};

/**
 * Report OTHERS' messages in the OPEN thread as delivered, then read — batched, once each.
 *
 * Both report points land in `messages`: a live arrival (`onMessageCreated` → mergeMessage) and the
 * `loadConversation` backfill (`setMessages(rows)`). One effect over that state therefore covers both,
 * and a message that arrived while this tab was away is reported on the next open. Two Set refs
 * mirror each other (delivered / read) and reset when the thread changes.
 *
 * Delivered is reported BEFORE read so the sender's tick progresses in order — grey, then blue —
 * even though both pushes leave within the same tick.
 */
export function useReceiptReporter(input: {
  channel: ReceiptChannel | null;
  messages: Message[];
  selfUserId: string | undefined;
  conversationId: string;
}) {
  const { channel, messages, selfUserId, conversationId } = input;
  const deliveredRef = useRef<Set<string>>(new Set());
  const readRef = useRef<Set<string>>(new Set());

  useEffect(() => {
    deliveredRef.current = new Set();
    readRef.current = new Set();
  }, [conversationId]);

  useEffect(() => {
    if (!channel || !selfUserId) return;
    const delivered = claimUnreported(messages, selfUserId, deliveredRef.current);
    const read = claimUnreported(messages, selfUserId, readRef.current);
    if (delivered.length === 0 && read.length === 0) return;
    void (async () => {
      await reportInChunks(delivered, deliveredRef.current, channel.markDeliveredBatch);
      await reportInChunks(read, readRef.current, channel.markReadBatch);
    })();
  }, [channel, messages, selfUserId]);
}
