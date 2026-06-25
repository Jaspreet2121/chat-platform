import { useEffect, useMemo, useRef, useState } from "react";
import { Loader2, MessageSquare, MessagesSquare } from "lucide-react";
import type { Message } from "@/lib/api";
import { EmptyState } from "./EmptyState";
import { MessageBubble } from "./MessageBubble";

// Chronological order (oldest → newest) so the newest message sits just above the composer and
// auto-scroll lands on it. Sorting at render time covers BOTH history load and live socket
// messages (mergeMessage may append out of order). Ties break on message_id for a stable order.
function sortChronologically(messages: Message[]): Message[] {
  return [...messages].sort((a, b) => {
    const at = Date.parse(a.created_at);
    const bt = Date.parse(b.created_at);
    const aTime = Number.isNaN(at) ? 0 : at;
    const bTime = Number.isNaN(bt) ? 0 : bt;
    if (aTime !== bTime) return aTime - bTime;
    return a.message_id < b.message_id ? -1 : a.message_id > b.message_id ? 1 : 0;
  });
}

export type MessageListProps = {
  messages: Message[];
  currentUserId?: string;
  isLoading: boolean;
  hasConversation: boolean;
  onEdit: (messageId: string, body: string) => Promise<void>;
  onDelete: (messageId: string) => Promise<void>;
  onReply?: (message: Message) => void;
  onForward?: (message: Message) => void;
  onReact?: (messageId: string, emoji: string) => void;
  onRemoveReaction?: (messageId: string) => void;
  onStar?: (messageId: string) => void;
  onUnstar?: (messageId: string) => void;
  /** A message to scroll to + highlight (from a search / starred result). The nonce re-triggers. */
  scrollTarget?: { id: string; n: number } | null;
};

export function MessageList({
  messages,
  currentUserId,
  isLoading,
  hasConversation,
  onEdit,
  onDelete,
  onReply,
  onForward,
  onReact,
  onRemoveReaction,
  onStar,
  onUnstar,
  scrollTarget
}: MessageListProps) {
  const bottomRef = useRef<HTMLDivElement | null>(null);
  const [highlightedId, setHighlightedId] = useState<string | null>(null);
  // The last scroll-target nonce we've acted on, so an incoming message doesn't re-trigger the jump.
  const handledNonceRef = useRef<number | null>(null);
  const highlightTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const ordered = useMemo(() => sortChronologically(messages), [messages]);
  // Lookup for resolving reply_to_message_id → the quoted message (when it's loaded).
  const byId = useMemo(() => {
    const map = new Map<string, Message>();
    for (const m of messages) map.set(m.message_id, m);
    return map;
  }, [messages]);

  // Keep the newest message in view as messages arrive (send + realtime) — UNLESS a jump-to-message is
  // pending, in which case we let the scroll effect below land on the target instead of the bottom.
  // (Reading the ref here is fine — it's inside an effect, not render.)
  useEffect(() => {
    if (scrollTarget && handledNonceRef.current !== scrollTarget.n) return;
    bottomRef.current?.scrollIntoView({ behavior: "smooth", block: "end" });
  }, [messages.length, scrollTarget]);

  // Scroll to + briefly highlight a search/starred target once it's loaded. Nonce-guarded so it fires
  // once per jump (not on every subsequent message). If the target isn't in the loaded page (an older
  // message beyond the fetched window), we do nothing — "load around a message" is out of scope here.
  useEffect(() => {
    if (!scrollTarget) return;
    if (handledNonceRef.current === scrollTarget.n) return;
    if (!messages.some((message) => message.message_id === scrollTarget.id)) return;

    handledNonceRef.current = scrollTarget.n;
    // Defer to the next frame so the target node is laid out; also keeps setState out of the effect body.
    const raf = requestAnimationFrame(() => {
      const node = document.getElementById(`msg-${scrollTarget.id}`);
      if (!node) return;
      node.scrollIntoView({ behavior: "smooth", block: "center" });
      setHighlightedId(scrollTarget.id);
      if (highlightTimerRef.current) clearTimeout(highlightTimerRef.current);
      highlightTimerRef.current = setTimeout(() => setHighlightedId(null), 2200);
    });
    return () => cancelAnimationFrame(raf);
  }, [scrollTarget, messages]);

  // Clear the highlight timer on unmount (the timer lives in a ref so it survives effect re-runs).
  useEffect(() => {
    return () => {
      if (highlightTimerRef.current) clearTimeout(highlightTimerRef.current);
    };
  }, []);

  if (!hasConversation) {
    return (
      <div className="flex-1">
        <EmptyState
          icon={<MessagesSquare className="h-6 w-6" aria-hidden />}
          title="Select or create a conversation"
          hint="Pick a conversation from the sidebar, or start a new one to begin chatting."
        />
      </div>
    );
  }

  if (isLoading) {
    return (
      <div className="flex flex-1 items-center justify-center text-faint">
        <Loader2 className="h-5 w-5 animate-spin" aria-hidden />
      </div>
    );
  }

  if (messages.length === 0) {
    return (
      <div className="flex-1">
        <EmptyState
          icon={<MessageSquare className="h-6 w-6" aria-hidden />}
          title="No messages yet"
          hint="Say hello — your first message will appear here."
        />
      </div>
    );
  }

  return (
    <div className="flex-1 space-y-3 overflow-y-auto px-4 py-5 sm:px-6">
      {ordered.map((message) => (
        <MessageBubble
          key={message.message_id}
          message={message}
          isOwn={message.sender_user_id === currentUserId}
          isHighlighted={highlightedId === message.message_id}
          currentUserId={currentUserId}
          quoted={
            message.reply_to_message_id ? byId.get(message.reply_to_message_id) ?? null : null
          }
          onEdit={onEdit}
          onDelete={onDelete}
          onReply={onReply}
          onForward={onForward}
          onReact={onReact}
          onRemoveReaction={onRemoveReaction}
          onStar={onStar}
          onUnstar={onUnstar}
        />
      ))}
      <div ref={bottomRef} />
    </div>
  );
}
