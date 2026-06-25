import { useEffect, useState } from "react";
import { Users, X } from "lucide-react";
import type { ConversationDetail } from "@/lib/api";
import { Avatar, IconButton } from "@/components";
import { cn } from "@/lib/cn";
import { PublicProfileCard } from "./PublicProfileCard";
import { useUserProfile } from "./useUserProfile";

export type ConversationDetailsPanelProps = {
  conversation: ConversationDetail | null;
  conversationId: string;
  title: string;
  isOpen: boolean;
  onClose: () => void;
  /** user_ids currently present in this conversation (have it open). */
  onlineUserIds?: string[];
  /** The viewer's own user id (to mark "You" in a profile). */
  currentUserId?: string;
};

function shortId(id: string): string {
  return `#${id.slice(0, 8)}`;
}

export function ConversationDetailsPanel({
  conversation,
  conversationId,
  title,
  isOpen,
  onClose,
  onlineUserIds = [],
  currentUserId
}: ConversationDetailsPanelProps) {
  const [profileUserId, setProfileUserId] = useState<string | null>(null);

  // Reset any open profile when the details panel itself closes.
  useEffect(() => {
    if (!isOpen) setProfileUserId(null);
  }, [isOpen]);

  if (!isOpen) return null;

  const type = conversation?.type ?? "conversation";
  const participants = conversation?.participants ?? [];
  const createdBy = conversation?.created_by;
  const online = new Set(onlineUserIds);
  const selectedRole =
    participants.find((p) => p.user_id === profileUserId)?.role;

  return (
    <div className="fixed inset-0 z-30 flex justify-end">
      {/* Backdrop */}
      <button
        type="button"
        aria-label="Close details"
        onClick={onClose}
        className="absolute inset-0 bg-black/50 backdrop-blur-sm animate-fade-in"
      />

      {/* Drawer — full-screen on mobile, fixed-width glass panel on desktop */}
      <aside className="relative flex h-full w-full flex-col border-l border-border/70 bg-surface/80 shadow-elevated backdrop-blur-xl animate-slide-in-right sm:w-96">
        <header className="flex items-center justify-between border-b border-border px-4 py-3">
          <h3 className="text-sm font-semibold text-fg">Conversation details</h3>
          <IconButton label="Close details" variant="ghost" onClick={onClose} type="button">
            <X className="h-5 w-5" aria-hidden />
          </IconButton>
        </header>

        <div className="flex-1 overflow-y-auto">
          {/* Identity */}
          <div className="flex flex-col items-center gap-3 border-b border-border px-6 py-7 text-center">
            <Avatar id={conversationId} name={title} size="lg" className="h-20 w-20 text-2xl" />
            <div>
              <p className="text-lg font-semibold text-fg">{title}</p>
              <span className="mt-1 inline-flex items-center rounded-full border border-border bg-elevated px-2.5 py-0.5 text-xs font-medium capitalize text-muted">
                {type}
              </span>
            </div>
          </div>

          {/* Participants */}
          <div className="px-4 py-4">
            <div className="mb-2 flex items-center gap-2 px-1 text-xs font-medium uppercase tracking-wide text-faint">
              <Users className="h-3.5 w-3.5" aria-hidden />
              {participants.length > 0
                ? `${participants.length} participant${participants.length === 1 ? "" : "s"}`
                : "Participants"}
            </div>

            {participants.length > 0 ? (
              <ul className="space-y-1">
                {participants.map((participant) => {
                  const isOnline = online.has(participant.user_id);
                  return (
                    <li key={participant.user_id}>
                      <button
                        type="button"
                        onClick={() => setProfileUserId(participant.user_id)}
                        title="View profile"
                        className="flex w-full items-center gap-3 rounded-xl px-2.5 py-2 text-left transition-colors hover:bg-elevated"
                      >
                        <ParticipantAvatar userId={participant.user_id} online={isOnline} />
                        <div className="min-w-0 flex-1">
                          <p className="truncate text-sm font-medium text-fg">
                            {shortId(participant.user_id)}
                          </p>
                          <p
                            className={cn(
                              "truncate text-xs capitalize",
                              isOnline ? "text-success" : "text-faint"
                            )}
                          >
                            {isOnline ? "online" : participant.role}
                          </p>
                        </div>
                        {createdBy && participant.user_id === createdBy ? (
                          <span className="rounded-full bg-brand-subtle/60 px-2 py-0.5 text-[11px] font-medium text-brand-hover">
                            owner
                          </span>
                        ) : null}
                      </button>
                    </li>
                  );
                })}
              </ul>
            ) : (
              <p className="px-1 text-sm text-muted">
                Participant details aren&apos;t available for this conversation yet.
              </p>
            )}
          </div>
        </div>
      </aside>

      {profileUserId ? (
        <PublicProfileCard
          userId={profileUserId}
          role={selectedRole}
          online={online.has(profileUserId)}
          isSelf={profileUserId === currentUserId}
          onClose={() => setProfileUserId(null)}
        />
      ) : null}
    </div>
  );
}

// A participant's avatar that resolves their real image (cached) with an initials fallback. A separate
// component so the cached profile hook can run per participant (hooks can't be called inside a .map).
function ParticipantAvatar({ userId, online }: { userId: string; online: boolean }) {
  const profile = useUserProfile(userId);
  return (
    <Avatar
      id={userId}
      name={profile?.display_name ?? undefined}
      imageUrl={profile?.avatar_url}
      size="sm"
      online={online}
    />
  );
}
