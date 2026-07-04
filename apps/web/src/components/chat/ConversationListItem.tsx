"use client";

import { motion } from "framer-motion";
import { CheckCheck } from "lucide-react";
import type { ConversationListItem as ConversationListItemData } from "@/lib/api";
import { Avatar } from "@/components";
import { cn } from "@/lib/cn";
import { SPRING } from "@/lib/motion";
import { useDirectPeer } from "./useDirectPeer";

export type ConversationListItemProps = {
  conversation: ConversationListItemData;
  isSelected: boolean;
  /** The viewer's user id — required to derive a direct chat's OTHER participant for the row title. */
  currentUserId?: string;
  onSelect: (conversationId: string) => void;
};

// Compact time for the row's right edge: today → clock time, else a short date (WhatsApp-style).
function listTime(iso?: string): string | null {
  if (!iso) return null;
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return null;
  const now = new Date();
  const sameDay =
    date.getFullYear() === now.getFullYear() &&
    date.getMonth() === now.getMonth() &&
    date.getDate() === now.getDate();
  return sameDay
    ? date.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" })
    : date.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

export function ConversationListItem({
  conversation,
  isSelected,
  currentUserId,
  onSelect
}: ConversationListItemProps) {
  const isDirect = conversation.type === "direct";
  // A direct chat's title is ALWAYS the derived peer (cached detail → participants minus me → profile),
  // never the stored title first: the stored title is the peer name from the CREATOR's perspective, so
  // for chats the other party started it is the viewer's OWN name. Until derived (loading / no session
  // yet), fall back to the stored title, then a generic label. Groups keep their stored title.
  const peer = useDirectPeer(conversation.conversation_id, isDirect, currentUserId);
  const title = isDirect
    ? peer.name || conversation.title || "Direct message"
    : conversation.title || conversation.conversation_id;
  const subtitle =
    conversation.last_message_preview || (isDirect ? "Direct message" : "Group chat");
  const time = listTime(conversation.updated_at);
  const unread = conversation.unread_count ?? 0;

  return (
    // Premium row: jewel avatar, unread-weighted name, and on the ACTIVE row a soft periwinkle
    // gradient tint + a rounded 3px accent bar hugging the left edge.
    <button
      type="button"
      onClick={() => onSelect(conversation.conversation_id)}
      className={cn(
        "relative flex w-full items-center gap-3 px-4 py-3 text-left transition-colors duration-150 ease-standard",
        "outline-none focus-visible:bg-brand-subtle/50",
        isSelected
          ? "bg-gradient-to-r from-brand-subtle/90 to-brand-subtle/40 shadow-subtle"
          : "hover:bg-elevated"
      )}
    >
      {isSelected ? (
        <span
          className="accent-gradient absolute left-0 top-1/2 h-9 w-[3px] -translate-y-1/2 rounded-r-full"
          aria-hidden
        />
      ) : null}

      {/* Real uploaded photo when the peer has one; deterministic gradient initials otherwise
          (groups keep initials — no group avatar concept yet). */}
      <Avatar
        id={isDirect ? peer.peerId ?? conversation.conversation_id : conversation.conversation_id}
        name={title}
        imageUrl={isDirect ? peer.avatarUrl : null}
      />

      <div className="min-w-0 flex-1">
        <div className="flex items-baseline justify-between gap-2">
          <p
            className={cn(
              "truncate text-sm text-fg",
              unread > 0 ? "font-semibold" : "font-medium"
            )}
          >
            {title}
          </p>
          {time ? (
            <span
              className={cn(
                "shrink-0 text-[11px] tabular-nums",
                unread > 0 ? "font-medium text-brand-hover" : "text-faint"
              )}
            >
              {time}
            </span>
          ) : null}
        </div>
        <div className="mt-0.5 flex items-center justify-between gap-2">
          <p className="truncate text-xs text-muted">{subtitle}</p>
          {unread > 0 ? (
            // Micro-animation: re-keying on the count springs the badge on each change (new message).
            <motion.span
              key={unread}
              initial={{ scale: 0.5, opacity: 0 }}
              animate={{ scale: 1, opacity: 1 }}
              transition={SPRING}
              className="accent-gradient inline-flex h-[18px] min-w-[18px] shrink-0 items-center justify-center rounded-full px-1.5 text-[10px] font-semibold leading-none text-white shadow-accent-glow"
            >
              {unread}
            </motion.span>
          ) : conversation.last_message_preview ? (
            <CheckCheck className="h-3.5 w-3.5 shrink-0 text-brand-hover/70" aria-hidden />
          ) : null}
        </div>
      </div>
    </button>
  );
}
