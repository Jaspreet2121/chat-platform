import { useEffect, useMemo, useRef } from "react";
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
};

export function MessageList({
  messages,
  currentUserId,
  isLoading,
  hasConversation,
  onEdit,
  onDelete
}: MessageListProps) {
  const bottomRef = useRef<HTMLDivElement | null>(null);
  const ordered = useMemo(() => sortChronologically(messages), [messages]);

  // Keep the newest message in view as messages arrive (send + realtime).
  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: "smooth", block: "end" });
  }, [messages.length]);

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
          onEdit={onEdit}
          onDelete={onDelete}
        />
      ))}
      <div ref={bottomRef} />
    </div>
  );
}
