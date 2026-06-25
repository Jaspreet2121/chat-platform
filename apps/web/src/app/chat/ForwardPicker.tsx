"use client";

import { useEffect } from "react";
import { Forward, X } from "lucide-react";
import type { ConversationListItem } from "@/lib/api";
import { Avatar, Card } from "@/components";

export function ForwardPicker({
  conversations,
  onPick,
  onClose
}: {
  conversations: ConversationListItem[];
  onPick: (conversation: ConversationListItem) => void;
  onClose: () => void;
}) {
  useEffect(() => {
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape") onClose();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm animate-fade-in">
      <button type="button" aria-label="Close" onClick={onClose} className="absolute inset-0" />

      <Card className="relative flex max-h-[70vh] w-full max-w-sm flex-col p-0 animate-scale-in">
        <header className="flex items-center justify-between border-b border-border px-4 py-3">
          <h3 className="flex items-center gap-2 text-sm font-semibold text-fg">
            <Forward className="h-4 w-4" aria-hidden /> Forward to…
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
          {conversations.length === 0 ? (
            <p className="p-6 text-center text-sm text-muted">No conversations to forward to.</p>
          ) : (
            <ul className="space-y-1">
              {conversations.map((conversation) => {
                const title = conversation.title || conversation.conversation_id;
                return (
                  <li key={conversation.conversation_id}>
                    <button
                      type="button"
                      onClick={() => onPick(conversation)}
                      className="flex w-full items-center gap-3 rounded-xl px-2.5 py-2 text-left transition-colors hover:bg-elevated"
                    >
                      <Avatar id={conversation.conversation_id} name={conversation.title ?? undefined} size="sm" />
                      <span className="min-w-0 flex-1 truncate text-sm font-medium text-fg">{title}</span>
                    </button>
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      </Card>
    </div>
  );
}
