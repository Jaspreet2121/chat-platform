import { ArrowLeft, MoreVertical, Phone, Video } from "lucide-react";
import { Avatar, IconButton } from "@/components";

export type ChatHeaderProps = {
  conversationId: string;
  title: string;
  /** Avatar color seed — defaults to the conversation id; set to the peer's id for a direct chat. */
  avatarId?: string;
  /** Avatar image (the peer's photo for a direct chat); falls back to initials when absent. */
  avatarUrl?: string | null;
  subtitle?: string;
  typingUser?: string | null;
  /** Mobile-only "back to list" affordance (deselects the conversation). */
  onBack?: () => void;
  /** Opens the conversation details panel (WhatsApp-style); the title/avatar area becomes clickable. */
  onOpenDetails?: () => void;
  /** True when someone else is present in this conversation (has it open). */
  online?: boolean;
};

export function ChatHeader({
  conversationId,
  title,
  avatarId,
  avatarUrl,
  subtitle,
  typingUser,
  onBack,
  onOpenDetails,
  online
}: ChatHeaderProps) {
  return (
    <header className="flex items-center gap-1.5 border-b border-border bg-surface px-2 py-2.5 sm:px-4">
      {onBack && (
        <div className="md:hidden">
          <IconButton label="Back to conversations" variant="ghost" onClick={onBack} type="button">
            <ArrowLeft className="h-5 w-5" aria-hidden />
          </IconButton>
        </div>
      )}
      <button
        type="button"
        onClick={onOpenDetails}
        disabled={!onOpenDetails || !conversationId}
        className="flex min-w-0 flex-1 items-center gap-3 rounded-xl px-1.5 py-1 text-left transition-colors enabled:hover:bg-elevated disabled:cursor-default"
        title={onOpenDetails && conversationId ? "View conversation details" : undefined}
      >
        {conversationId && (
          <Avatar
            id={avatarId || conversationId}
            name={title}
            imageUrl={avatarUrl ?? undefined}
            online={online}
          />
        )}
        <div className="min-w-0">
          <h2 className="truncate text-[15px] font-semibold text-fg">{title}</h2>
          {typingUser ? (
            <p className="truncate text-xs font-medium text-brand-hover">typing…</p>
          ) : online ? (
            <p className="truncate text-xs font-medium text-brand-hover">Active now</p>
          ) : subtitle ? (
            <p className="truncate text-xs text-muted">{subtitle}</p>
          ) : null}
        </div>
      </button>

      {/* Right-side actions: calls are visual-parity placeholders (coming soon); the menu opens the
          real details panel. Hidden entirely with no conversation. */}
      {conversationId ? (
        <div className="flex shrink-0 items-center gap-0.5">
          <span
            className="hidden h-10 w-10 cursor-not-allowed items-center justify-center rounded-xl text-faint sm:flex"
            title="Voice call — coming soon"
            aria-hidden
          >
            <Phone className="h-[18px] w-[18px]" />
          </span>
          <span
            className="hidden h-10 w-10 cursor-not-allowed items-center justify-center rounded-xl text-faint sm:flex"
            title="Video call — coming soon"
            aria-hidden
          >
            <Video className="h-[18px] w-[18px]" />
          </span>
          <IconButton
            label="Conversation details"
            variant="ghost"
            onClick={onOpenDetails}
            type="button"
            disabled={!onOpenDetails}
          >
            <MoreVertical className="h-5 w-5" aria-hidden />
          </IconButton>
        </div>
      ) : null}
    </header>
  );
}
