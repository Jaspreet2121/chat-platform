import type { ConversationListItem as ConversationListItemData } from "@/lib/api";
import { Avatar } from "@/components";
import { cn } from "@/lib/cn";
import { useDirectPeerName } from "./useDirectPeer";

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
  const peerName = useDirectPeerName(conversation.conversation_id, isDirect, currentUserId);
  const title = isDirect
    ? peerName || conversation.title || "Direct message"
    : conversation.title || conversation.conversation_id;
  const subtitle =
    conversation.last_message_preview || (isDirect ? "Direct message" : "Group chat");
  const time = listTime(conversation.updated_at);

  return (
    // Flat, full-bleed row (WhatsApp-calm): no card box, no accent bar — selection and hover are
    // quiet full-row tints only.
    <button
      type="button"
      onClick={() => onSelect(conversation.conversation_id)}
      className={cn(
        "flex w-full items-center gap-3 px-3 py-2.5 text-left transition-colors duration-150",
        "outline-none focus-visible:bg-elevated/60",
        isSelected ? "bg-elevated" : "hover:bg-elevated/60"
      )}
    >
      <Avatar id={conversation.conversation_id} name={title} />
      <div className="min-w-0 flex-1">
        <div className="flex items-baseline justify-between gap-2">
          <p className="truncate text-sm text-fg">{title}</p>
          {time ? (
            <span className="shrink-0 text-[11px] tabular-nums text-faint">{time}</span>
          ) : null}
        </div>
        <div className="mt-0.5 flex items-center justify-between gap-2">
          <p className="truncate text-xs text-muted">{subtitle}</p>
          {conversation.unread_count ? (
            <span className="inline-flex h-4 min-w-4 shrink-0 items-center justify-center rounded-full bg-brand px-1 text-[10px] font-medium leading-none text-white">
              {conversation.unread_count}
            </span>
          ) : null}
        </div>
      </div>
    </button>
  );
}
