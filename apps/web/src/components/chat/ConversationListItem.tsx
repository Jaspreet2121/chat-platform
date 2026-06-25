import type { ConversationListItem as ConversationListItemData } from "@/lib/api";
import { Avatar } from "@/components";
import { cn } from "@/lib/cn";

export type ConversationListItemProps = {
  conversation: ConversationListItemData;
  isSelected: boolean;
  onSelect: (conversationId: string) => void;
};

export function ConversationListItem({
  conversation,
  isSelected,
  onSelect
}: ConversationListItemProps) {
  const isDirect = conversation.type === "direct";
  // Direct chats are stored with the peer's name as the title (no participant data on list items, so
  // this is the best available label — the header derives the live peer from the loaded detail).
  const title =
    conversation.title || (isDirect ? "Direct message" : conversation.conversation_id);
  const subtitle =
    conversation.last_message_preview || (isDirect ? "Direct message" : "Group chat");

  return (
    <button
      type="button"
      onClick={() => onSelect(conversation.conversation_id)}
      className={cn(
        // Tasteful left accent bar on the selected row (via ::before, no layout shift) + a soft
        // brand-tinted surface; others get a quiet hover.
        "relative flex w-full items-center gap-3 rounded-xl px-2.5 py-2.5 text-left transition-all duration-150",
        "before:absolute before:left-0 before:top-1/2 before:h-7 before:-translate-y-1/2 before:rounded-r-full before:bg-brand before:transition-all before:content-['']",
        isSelected
          ? "bg-brand-subtle/60 ring-1 ring-inset ring-brand/30 before:w-1 before:opacity-100"
          : "before:w-0 before:opacity-0 hover:bg-brand-subtle/30"
      )}
    >
      <Avatar id={conversation.conversation_id} name={conversation.title ?? undefined} />
      <div className="min-w-0 flex-1">
        <p className={cn("truncate text-sm font-medium", isSelected ? "text-fg" : "text-fg/90")}>
          {title}
        </p>
        <p className="truncate text-xs text-muted">{subtitle}</p>
      </div>
      {conversation.unread_count ? (
        <span className="ml-auto inline-flex h-5 min-w-5 items-center justify-center rounded-full bg-brand px-1.5 text-[11px] font-semibold text-white">
          {conversation.unread_count}
        </span>
      ) : null}
    </button>
  );
}
