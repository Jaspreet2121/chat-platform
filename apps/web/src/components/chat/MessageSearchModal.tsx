"use client";

import { useEffect } from "react";
import { Search, X } from "lucide-react";
import type { ConversationListItem } from "@/lib/api";
import { Card } from "@/components";
import { MessageSearch } from "./MessageSearch";

export type MessageSearchModalProps = {
  isOpen: boolean;
  onClose: () => void;
  conversations: ConversationListItem[];
  currentUserId?: string;
  onJump: (conversationId: string, messageId: string) => void;
};

// "Search messages" sheet — opened from the "+" menu. Wraps the existing (unchanged) privacy-scoped
// MessageSearch; opening a result jumps to it and closes the sheet. Esc / backdrop close.
export function MessageSearchModal({
  isOpen,
  onClose,
  conversations,
  currentUserId,
  onJump
}: MessageSearchModalProps) {
  useEffect(() => {
    if (!isOpen) return;
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape") onClose();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [isOpen, onClose]);

  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 z-40 flex items-start justify-center bg-black/60 p-4 pt-[12vh] backdrop-blur-sm animate-fade-in">
      <button type="button" aria-label="Close" onClick={onClose} className="absolute inset-0" />

      <Card className="relative w-full max-w-md p-0 shadow-glow-sm animate-bubble-in">
        <header className="flex items-center justify-between border-b border-border px-4 py-3">
          <div className="flex items-center gap-2 text-sm font-semibold text-fg">
            <Search className="h-4 w-4 text-brand-hover" aria-hidden />
            Search messages
          </div>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close"
            className="rounded-lg p-1.5 text-muted transition-colors hover:bg-elevated hover:text-fg"
          >
            <X className="h-4 w-4" aria-hidden />
          </button>
        </header>

        <div className="p-3">
          <MessageSearch
            conversations={conversations}
            currentUserId={currentUserId}
            onJump={onJump}
            autoFocus
            onJumped={onClose}
          />
        </div>
      </Card>
    </div>
  );
}
