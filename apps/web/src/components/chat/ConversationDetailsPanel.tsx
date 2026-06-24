import { Users, X } from "lucide-react";
import type { ConversationDetail } from "@/lib/api";
import { Avatar, IconButton } from "@/components";

export type ConversationDetailsPanelProps = {
  conversation: ConversationDetail | null;
  conversationId: string;
  title: string;
  isOpen: boolean;
  onClose: () => void;
};

function shortId(id: string): string {
  return `#${id.slice(0, 8)}`;
}

export function ConversationDetailsPanel({
  conversation,
  conversationId,
  title,
  isOpen,
  onClose
}: ConversationDetailsPanelProps) {
  if (!isOpen) return null;

  const type = conversation?.type ?? "conversation";
  const participants = conversation?.participants ?? [];
  const createdBy = conversation?.created_by;

  return (
    <div className="fixed inset-0 z-30 flex justify-end">
      {/* Backdrop */}
      <button
        type="button"
        aria-label="Close details"
        onClick={onClose}
        className="absolute inset-0 bg-black/50 animate-fade-in"
      />

      {/* Drawer — full-screen on mobile, fixed-width panel on desktop */}
      <aside className="relative flex h-full w-full flex-col border-l border-border bg-surface shadow-elevated animate-slide-in-right sm:w-96">
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
                {participants.map((participant) => (
                  <li
                    key={participant.user_id}
                    className="flex items-center gap-3 rounded-xl px-2.5 py-2 transition-colors hover:bg-elevated"
                  >
                    <Avatar id={participant.user_id} size="sm" />
                    <div className="min-w-0 flex-1">
                      <p className="truncate text-sm font-medium text-fg">
                        {shortId(participant.user_id)}
                      </p>
                      <p className="truncate text-xs text-faint capitalize">{participant.role}</p>
                    </div>
                    {createdBy && participant.user_id === createdBy ? (
                      <span className="rounded-full bg-brand-subtle/60 px-2 py-0.5 text-[11px] font-medium text-brand-hover">
                        owner
                      </span>
                    ) : null}
                  </li>
                ))}
              </ul>
            ) : (
              <p className="px-1 text-sm text-muted">
                Participant details aren&apos;t available for this conversation yet.
              </p>
            )}
          </div>
        </div>
      </aside>
    </div>
  );
}
