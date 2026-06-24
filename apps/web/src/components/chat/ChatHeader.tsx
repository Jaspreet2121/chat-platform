import { ArrowLeft } from "lucide-react";
import { Avatar, IconButton } from "@/components";

export type ChatHeaderProps = {
  conversationId: string;
  title: string;
  subtitle?: string;
  typingUser?: string | null;
  /** Mobile-only "back to list" affordance (deselects the conversation). */
  onBack?: () => void;
};

export function ChatHeader({ conversationId, title, subtitle, typingUser, onBack }: ChatHeaderProps) {
  return (
    <header className="flex items-center gap-2 border-b border-border bg-surface/60 px-3 py-3 backdrop-blur sm:px-6">
      {onBack && (
        <div className="md:hidden">
          <IconButton label="Back to conversations" variant="ghost" onClick={onBack} type="button">
            <ArrowLeft className="h-5 w-5" aria-hidden />
          </IconButton>
        </div>
      )}
      {conversationId && <Avatar id={conversationId} name={title} />}
      <div className="min-w-0">
        <h2 className="truncate text-sm font-semibold text-fg">{title}</h2>
        {typingUser ? (
          <p className="truncate text-xs text-brand-hover">typing…</p>
        ) : subtitle ? (
          <p className="truncate text-xs text-muted">{subtitle}</p>
        ) : null}
      </div>
    </header>
  );
}
