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
  const title = conversation.title || conversation.conversation_id;
  const subtitle = conversation.last_message_preview || conversation.type;

  return (
    <button
      type="button"
      onClick={() => onSelect(conversation.conversation_id)}
      className={cn(
        "flex w-full items-center gap-3 rounded-xl px-2.5 py-2.5 text-left transition-colors",
        isSelected ? "bg-brand-subtle/60 ring-1 ring-brand/40" : "hover:bg-elevated"
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
