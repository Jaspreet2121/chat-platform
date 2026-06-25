"use client";

import { useEffect, useState } from "react";
import { Loader2, Star, X } from "lucide-react";
import type { ConversationListItem, Message } from "@/lib/api";
import { listStarred } from "@/lib/api";
import { Card } from "@/components";
import { formatTime } from "./format";

export type StarredPanelProps = {
  isOpen: boolean;
  onClose: () => void;
  conversations: ConversationListItem[];
  currentUserId?: string;
  /** Open the conversation a starred message belongs to (then close the panel). */
  onJump: (conversationId: string) => void;
};

// Modal listing the caller's starred messages across all conversations (newest-starred first).
export function StarredPanel({
  isOpen,
  onClose,
  conversations,
  currentUserId,
  onJump
}: StarredPanelProps) {
  const [messages, setMessages] = useState<Message[]>([]);
  const [isLoading, setIsLoading] = useState(false);

  useEffect(() => {
    if (!isOpen) return;

    let cancelled = false;

    // Defer state updates out of the effect body (avoids cascading-render lint); fetch on open.
    const id = setTimeout(() => {
      setIsLoading(true);
      listStarred()
        .then((res) => {
          if (!cancelled) setMessages(res.messages ?? []);
        })
        .catch(() => {
          if (!cancelled) setMessages([]);
        })
        .finally(() => {
          if (!cancelled) setIsLoading(false);
        });
    }, 0);

    return () => {
      cancelled = true;
      clearTimeout(id);
    };
  }, [isOpen]);

  useEffect(() => {
    if (!isOpen) return;
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape") onClose();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [isOpen, onClose]);

  if (!isOpen) return null;

  function titleFor(conversationId: string) {
    return (
      conversations.find((c) => c.conversation_id === conversationId)?.title ||
      `#${conversationId.slice(0, 8)}`
    );
  }

  function jump(conversationId: string) {
    onJump(conversationId);
    onClose();
  }

  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center bg-black/60 p-4 animate-fade-in">
      <button type="button" aria-label="Close" onClick={onClose} className="absolute inset-0" />

      <Card className="relative flex max-h-[70vh] w-full max-w-md flex-col p-0 animate-scale-in">
        <header className="flex items-center justify-between border-b border-border px-4 py-3">
          <h3 className="flex items-center gap-2 text-sm font-semibold text-fg">
            <Star className="h-4 w-4 text-amber-400" fill="currentColor" aria-hidden /> Starred
            messages
          </h3>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close"
            className="rounded-lg p-1.5 text-muted transition-colors hover:bg-elevated hover:text-fg"
          >
            <X className="h-4 w-4" aria-hidden />
          </button>
        </header>

        <div className="flex-1 overflow-y-auto p-2">
          {isLoading ? (
            <div className="flex justify-center py-10 text-faint">
              <Loader2 className="h-5 w-5 animate-spin" aria-hidden />
            </div>
          ) : messages.length === 0 ? (
            <div className="px-6 py-10 text-center">
              <Star className="mx-auto mb-2 h-7 w-7 text-faint" aria-hidden />
              <p className="text-sm font-medium text-fg">No starred messages yet</p>
              <p className="mt-1 text-xs text-muted">
                Star a message from its ⋯ menu to keep it here.
              </p>
            </div>
          ) : (
            <ul className="space-y-1">
              {messages.map((message) => (
                <li key={message.message_id}>
                  <button
                    type="button"
                    onClick={() => jump(message.conversation_id)}
                    className="w-full rounded-xl px-3 py-2.5 text-left transition-colors hover:bg-elevated"
                  >
                    <div className="flex items-baseline justify-between gap-2">
                      <span className="truncate text-xs font-medium text-brand-hover">
                        {titleFor(message.conversation_id)}
                      </span>
                      <span className="shrink-0 text-[10px] text-faint">
                        {formatTime(message.created_at)}
                      </span>
                    </div>
                    <p className="mt-0.5 line-clamp-2 text-sm text-fg">{snippet(message)}</p>
                    <p className="mt-0.5 text-[11px] text-faint">
                      {message.sender_user_id === currentUserId
                        ? "You"
                        : `#${message.sender_user_id.slice(0, 8)}`}
                    </p>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      </Card>
    </div>
  );
}

function snippet(message: Message): string {
  if (message.status === "deleted") return "Message deleted";
  if (message.media_id) {
    const contentType = (message.metadata?.content_type as string) || "";
    if (contentType.startsWith("image/")) return "📷 Photo";
    if (contentType.startsWith("video/")) return "🎬 Video";
    if (contentType.startsWith("audio/")) return "🎤 Audio";
    return "📎 Attachment";
  }
  return message.body || "Message";
}
