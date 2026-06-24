import { ArrowLeft } from "lucide-react";
import { Avatar, IconButton } from "@/components";

export type ChatHeaderProps = {
  conversationId: string;
  title: string;
  subtitle?: string;
  typingUser?: string | null;
  /** Mobile-only "back to list" affordance (deselects the conversation). */
  onBack?: () => void;
  /** Opens the conversation details panel (WhatsApp-style); the title/avatar area becomes clickable. */
  onOpenDetails?: () => void;
};

export function ChatHeader({
  conversationId,
  title,
  subtitle,
  typingUser,
  onBack,
  onOpenDetails
}: ChatHeaderProps) {
  return (
    <header className="flex items-center gap-2 border-b border-border bg-surface/60 px-3 py-3 backdrop-blur sm:px-6">
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
        className="flex min-w-0 flex-1 items-center gap-3 rounded-lg px-1 py-0.5 text-left transition-colors enabled:hover:bg-elevated disabled:cursor-default"
        title={onOpenDetails && conversationId ? "View conversation details" : undefined}
      >
        {conversationId && <Avatar id={conversationId} name={title} />}
        <div className="min-w-0">
          <h2 className="truncate text-sm font-semibold text-fg">{title}</h2>
          {typingUser ? (
            <p className="truncate text-xs text-brand-hover">typing…</p>
          ) : subtitle ? (
            <p className="truncate text-xs text-muted">{subtitle}</p>
          ) : null}
        </div>
      </button>
    </header>
  );
}
