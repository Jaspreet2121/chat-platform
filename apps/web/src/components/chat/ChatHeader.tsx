import { ArrowLeft, Lock, MoreVertical, Phone, ShieldCheck, Video } from "lucide-react";
import { useState } from "react";
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
  /** DM-only: start a 1:1 voice call with the peer. When set, the phone icon becomes a live call button. */
  onStartCall?: () => void;
  /** DM-only: start a 1:1 video call. When set, the video icon becomes a live call button (Phase 2). */
  onStartVideoCall?: () => void;
  /** 108: true for a secret (E2EE) conversation — shows the lock + hides "Turn on encryption". */
  secret?: boolean;
  /** 108: DM-only — offer "Turn on encryption" (opens the confirm sheet in the page). */
  onTurnOnEncryption?: () => void;
  /** 108: open the safety-number screen (secret chats only). */
  onOpenSafetyNumbers?: () => void;
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
  online,
  onStartCall,
  onStartVideoCall,
  secret,
  onTurnOnEncryption,
  onOpenSafetyNumbers
}: ChatHeaderProps) {
  const [menuOpen, setMenuOpen] = useState(false);
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

      {/* Right-side actions. Voice + video calls are live for DMs (onStartCall / onStartVideoCall set).
          The menu opens the details panel. Hidden entirely with no conversation. */}
      {conversationId ? (
        <div className="flex shrink-0 items-center gap-0.5">
          {onStartCall ? (
            <IconButton label="Start voice call" variant="ghost" onClick={onStartCall} type="button">
              <Phone className="h-[18px] w-[18px]" aria-hidden />
            </IconButton>
          ) : (
            <span
              className="hidden h-10 w-10 cursor-not-allowed items-center justify-center rounded-xl text-faint sm:flex"
              title="Voice call — coming soon"
              aria-hidden
            >
              <Phone className="h-[18px] w-[18px]" />
            </span>
          )}
          {onStartVideoCall ? (
            <IconButton label="Start video call" variant="ghost" onClick={onStartVideoCall} type="button">
              <Video className="h-[18px] w-[18px]" aria-hidden />
            </IconButton>
          ) : (
            <span
              className="hidden h-10 w-10 cursor-not-allowed items-center justify-center rounded-xl text-faint sm:flex"
              title="Video call — coming soon"
              aria-hidden
            >
              <Video className="h-[18px] w-[18px]" />
            </span>
          )}
          {secret ? (
            <span
              className="hidden h-9 items-center gap-1 rounded-lg bg-brand-subtle/40 px-2 text-[11px] font-medium text-brand-hover sm:inline-flex"
              title="End-to-end encrypted"
            >
              <Lock className="h-3.5 w-3.5" aria-hidden />
              Encrypted
            </span>
          ) : null}
          <div className="relative">
            <IconButton
              label="Conversation options"
              variant="ghost"
              onClick={() => setMenuOpen((open) => !open)}
              type="button"
            >
              <MoreVertical className="h-5 w-5" aria-hidden />
            </IconButton>
            {menuOpen ? (
              <>
                <button
                  type="button"
                  aria-hidden
                  tabIndex={-1}
                  className="fixed inset-0 z-30 cursor-default"
                  onClick={() => setMenuOpen(false)}
                />
                <div className="absolute right-0 top-11 z-40 w-56 rounded-xl border border-border bg-surface p-1 shadow-elevated">
                  {onOpenDetails ? (
                    <MenuItem
                      onClick={() => {
                        setMenuOpen(false);
                        onOpenDetails();
                      }}
                    >
                      Conversation details
                    </MenuItem>
                  ) : null}
                  {secret ? (
                    onOpenSafetyNumbers ? (
                      <MenuItem
                        icon={<ShieldCheck className="h-4 w-4" aria-hidden />}
                        onClick={() => {
                          setMenuOpen(false);
                          onOpenSafetyNumbers();
                        }}
                      >
                        Safety numbers
                      </MenuItem>
                    ) : null
                  ) : onTurnOnEncryption ? (
                    <MenuItem
                      icon={<Lock className="h-4 w-4" aria-hidden />}
                      onClick={() => {
                        setMenuOpen(false);
                        onTurnOnEncryption();
                      }}
                    >
                      Turn on encryption
                    </MenuItem>
                  ) : null}
                </div>
              </>
            ) : null}
          </div>
        </div>
      ) : null}
    </header>
  );
}

function MenuItem({
  children,
  icon,
  onClick
}: {
  children: React.ReactNode;
  icon?: React.ReactNode;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left text-sm text-fg hover:bg-elevated"
    >
      {icon}
      {children}
    </button>
  );
}
