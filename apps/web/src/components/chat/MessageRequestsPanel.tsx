"use client";

import { useState } from "react";
import { Check, MessageSquareWarning, X } from "lucide-react";
import type { ConversationListItem as ConversationListItemData } from "@/lib/api";
import { acceptMessageRequest, declineMessageRequest } from "@/lib/api";
import { cn } from "@/lib/cn";
import { EmptyState } from "./EmptyState";

export type MessageRequestsPanelProps = {
  requests: ConversationListItemData[];
  isLoading: boolean;
  /** Re-fetch both the requests bucket and the main inbox — a decision moves a row between them. */
  onAnswered: () => void;
};

/**
 * MESSAGE REQUESTS (128) — the bucket Android and iOS have shipped and web did not, which is the
 * whole reason a recipient could be stuck pending forever.
 *
 * Two things this deliberately does NOT do:
 *
 *   * It does not open the chat on tap. Answering is the decision; reading first is a separate
 *     feature and, more importantly, opening would mark it read and badge a chat the user has not
 *     accepted. Accept, then read.
 *   * It does not warn before Declining. Decline is silent to the sender and reversible in the
 *     sense that nothing is deleted (the chat lands in archived, the block is listed in settings) —
 *     a confirmation here would make declining feel risky, which is the opposite of the point.
 */
export function MessageRequestsPanel({ requests, isLoading, onAnswered }: MessageRequestsPanelProps) {
  // Per-row, so one slow decision cannot lock the others, and a failure is attributable to its row.
  const [pending, setPending] = useState<Record<string, "accept" | "decline">>({});
  const [errors, setErrors] = useState<Record<string, string>>({});

  async function answer(conversationId: string, decision: "accept" | "decline") {
    setPending((current) => ({ ...current, [conversationId]: decision }));
    setErrors((current) => {
      const next = { ...current };
      delete next[conversationId];
      return next;
    });

    try {
      if (decision === "accept") {
        await acceptMessageRequest(conversationId);
      } else {
        await declineMessageRequest(conversationId);
      }

      onAnswered();
    } catch (error) {
      // 404 request_not_found means it is already gone — answered on another device, or the sender's
      // side changed. That is not an error the user can act on, so re-sync rather than shout.
      const status = (error as { status?: number }).status;

      if (status === 404) {
        onAnswered();
      } else {
        setErrors((current) => ({
          ...current,
          [conversationId]: "Couldn't do that. Try again."
        }));
      }
    } finally {
      setPending((current) => {
        const next = { ...current };
        delete next[conversationId];
        return next;
      });
    }
  }

  if (isLoading) {
    return <EmptyState title="Loading requests…" />;
  }

  if (requests.length === 0) {
    return (
      <EmptyState
        icon={<MessageSquareWarning className="h-6 w-6" aria-hidden />}
        title="No message requests"
        hint="First messages from people you don't know wait here."
      />
    );
  }

  return (
    <div>
      <p className="px-4 pb-2 pt-1 text-xs text-muted">
        These people aren&apos;t in any of your chats yet. Accepting lets them message you normally.
      </p>

      <ul className="divide-y divide-border">
        {requests.map((request) => {
          const id = request.conversation_id;
          const busy = pending[id];
          const error = errors[id];
          const name = request.title?.trim() || "Unknown";

          return (
            <li key={id} className="px-4 py-3">
              <p className="truncate text-sm font-medium text-fg">{name}</p>

              {request.last_message_preview ? (
                <p className="mt-0.5 truncate text-xs text-muted">{request.last_message_preview}</p>
              ) : null}

              <div className="mt-2.5 flex items-center gap-2">
                <button
                  type="button"
                  disabled={Boolean(busy)}
                  onClick={() => answer(id, "accept")}
                  aria-label={`Accept message request from ${name}`}
                  className={cn(
                    "inline-flex min-h-[36px] items-center gap-1.5 rounded-full px-3.5 text-xs font-medium",
                    "accent-gradient text-white shadow-accent-glow transition-opacity",
                    "outline-none focus-visible:ring-2 focus-visible:ring-brand-ring",
                    busy ? "opacity-60" : "hover:opacity-90"
                  )}
                >
                  <Check className="h-3.5 w-3.5" aria-hidden />
                  {busy === "accept" ? "Accepting…" : "Accept"}
                </button>

                <button
                  type="button"
                  disabled={Boolean(busy)}
                  onClick={() => answer(id, "decline")}
                  aria-label={`Decline message request from ${name}`}
                  className={cn(
                    "inline-flex min-h-[36px] items-center gap-1.5 rounded-full px-3.5 text-xs",
                    "bg-elevated text-muted transition-colors",
                    "outline-none focus-visible:ring-2 focus-visible:ring-brand-ring",
                    busy ? "opacity-60" : "hover:text-fg"
                  )}
                >
                  <X className="h-3.5 w-3.5" aria-hidden />
                  {busy === "decline" ? "Declining…" : "Decline"}
                </button>
              </div>

              {error ? <p className="mt-1.5 text-xs text-danger">{error}</p> : null}
            </li>
          );
        })}
      </ul>
    </div>
  );
}
