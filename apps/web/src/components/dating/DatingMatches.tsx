"use client";

import { useState } from "react";
import { MessageCircle, MoreVertical, Sparkles } from "lucide-react";
import { Button } from "@/components";
import { EmptyState } from "@/components/chat";
import type { DatingMatchEntry } from "@/lib/api";

export type DatingMatchesProps = {
  matches: DatingMatchEntry[];
  loaded: boolean;
  onOpenChat: (conversationId: string) => void;
  onUnmatch: (match: DatingMatchEntry) => Promise<void>;
};

/** Relative matched_at — coarse on purpose ("just now", "3h", "2d", then a date). */
export function relativeMatchedAt(iso: string | null, now = Date.now()): string {
  if (!iso) return "";
  const then = Date.parse(iso);
  if (Number.isNaN(then)) return "";
  const seconds = Math.max(0, Math.floor((now - then) / 1000));
  if (seconds < 60) return "just now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)}h ago`;
  if (seconds < 7 * 86_400) return `${Math.floor(seconds / 86_400)}d ago`;
  return new Date(then).toLocaleDateString();
}

export function DatingMatches({ matches, loaded, onOpenChat, onUnmatch }: DatingMatchesProps) {
  const [menuFor, setMenuFor] = useState<string | null>(null);
  const [confirmFor, setConfirmFor] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  if (loaded && matches.length === 0) {
    return (
      <EmptyState
        icon={<Sparkles className="h-6 w-6" aria-hidden />}
        title="No matches yet"
        hint="Keep swiping — a match happens when you like each other."
      />
    );
  }

  return (
    <ul className="divide-y divide-border/60 p-2">
      {matches.map((match) => (
        <li key={match.match_id} className="relative flex items-center gap-3 px-2 py-3">
          <div className="h-12 w-12 shrink-0 overflow-hidden rounded-full bg-brand-subtle/40">
            {match.photos[0] ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={match.photos[0]} alt="" className="h-full w-full object-cover" />
            ) : (
              <div className="flex h-full w-full items-center justify-center font-semibold text-brand-hover">
                {(match.display_name ?? "?").slice(0, 1)}
              </div>
            )}
          </div>
          <div className="min-w-0 flex-1">
            <p className="truncate text-sm font-medium text-fg">
              {match.display_name ?? "Someone"}
              {match.age != null && <span className="font-normal text-muted">, {match.age}</span>}
            </p>
            <p className="text-xs text-muted">Matched {relativeMatchedAt(match.matched_at)}</p>
          </div>
          {match.conversation_id && (
            <Button
              type="button"
              size="sm"
              onClick={() => onOpenChat(match.conversation_id as string)}
            >
              <MessageCircle className="mr-1.5 h-4 w-4" aria-hidden />
              Open chat
            </Button>
          )}
          <button
            type="button"
            aria-label={`More options for ${match.display_name ?? "this match"}`}
            onClick={() => setMenuFor((id) => (id === match.match_id ? null : match.match_id))}
            className="rounded-lg p-1.5 text-muted hover:bg-elevated hover:text-fg"
          >
            <MoreVertical className="h-4 w-4" aria-hidden />
          </button>

          {menuFor === match.match_id && confirmFor !== match.match_id && (
            <div className="absolute right-2 top-12 z-10 rounded-xl border border-border bg-surface p-1 shadow-elevated">
              <button
                type="button"
                onClick={() => setConfirmFor(match.match_id)}
                className="rounded-lg px-3 py-1.5 text-sm text-red-400 hover:bg-red-500/10"
              >
                Unmatch
              </button>
            </div>
          )}

          {confirmFor === match.match_id && (
            <div className="absolute right-2 top-12 z-10 w-60 rounded-xl border border-border bg-surface p-3 shadow-elevated">
              <p className="text-sm text-fg">Unmatch {match.display_name ?? "them"}?</p>
              <p className="mt-1 text-xs text-muted">
                They won&apos;t be notified. The chat stays.
              </p>
              <div className="mt-2 flex gap-2">
                <Button
                  type="button"
                  variant="danger"
                  size="sm"
                  disabled={busy}
                  onClick={async () => {
                    setBusy(true);
                    try {
                      await onUnmatch(match);
                    } finally {
                      setBusy(false);
                      setConfirmFor(null);
                      setMenuFor(null);
                    }
                  }}
                >
                  Unmatch
                </Button>
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  onClick={() => {
                    setConfirmFor(null);
                    setMenuFor(null);
                  }}
                >
                  Cancel
                </Button>
              </div>
            </div>
          )}
        </li>
      ))}
    </ul>
  );
}
