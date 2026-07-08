"use client";

import { Check, UserPlus, X } from "lucide-react";
import { Avatar } from "@/components";

export type LinkApprovalPromptProps = {
  userId: string;
  userName: string;
  onApprove: () => void;
  onDeny: () => void;
};

/**
 * Host's "<name> wants to join" prompt for a call-link approval request (L3b). A COMPACT top-center card
 * (not a full-screen ring) — the host is already in the call grid (z-[60]), so this sits above it (z-[75])
 * without covering the call. Approve → admit + connect; Deny → reject. One request shown at a time (queued).
 */
export function LinkApprovalPrompt({ userId, userName, onApprove, onDeny }: LinkApprovalPromptProps) {
  return (
    <div className="fixed inset-x-0 top-0 z-[75] flex justify-center px-3 pt-[calc(env(safe-area-inset-top)+0.75rem)]">
      <div className="flex w-full max-w-sm items-center gap-3 rounded-2xl border border-border bg-surface px-3 py-2.5 shadow-xl animate-slide-up">
        <Avatar id={userId} name={userName} size="sm" />
        <div className="min-w-0 flex-1">
          <p className="truncate text-sm font-medium text-fg">{userName}</p>
          <p className="text-xs text-muted">wants to join the call</p>
        </div>
        <button
          type="button"
          onClick={onDeny}
          aria-label={`Deny ${userName}`}
          className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-elevated text-danger transition-transform active:scale-95"
        >
          <X className="h-4 w-4" aria-hidden />
        </button>
        <button
          type="button"
          onClick={onApprove}
          aria-label={`Approve ${userName}`}
          className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-emerald-500 text-white shadow-lg transition-transform active:scale-95"
        >
          <Check className="h-4 w-4" aria-hidden />
        </button>
      </div>
    </div>
  );
}

/** Full-screen "waiting for the host" screen shown to a pending joiner (L3b). */
export function LinkWaitingScreen({
  video,
  onCancel
}: {
  video: boolean;
  onCancel: () => void;
}) {
  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Waiting for the host"
      className="fixed inset-0 z-[60] flex flex-col items-center justify-center gap-6 bg-black/80 p-8 backdrop-blur-md animate-fade-in"
    >
      <div className="flex flex-col items-center gap-4 text-center">
        <span className="relative flex h-16 w-16 items-center justify-center rounded-full bg-white/10">
          <span className="absolute inset-0 animate-ping rounded-full bg-white/15" aria-hidden />
          <UserPlus className="h-7 w-7 text-white" aria-hidden />
        </span>
        <div>
          <h2 className="text-lg font-semibold text-white">Waiting for the host to let you in…</h2>
          <p className="mt-1 text-sm text-white/70">{video ? "Video call" : "Voice call"}</p>
        </div>
      </div>
      <button
        type="button"
        onClick={onCancel}
        className="rounded-full bg-white/10 px-5 py-2 text-sm font-medium text-white/90 transition-transform active:scale-95"
      >
        Cancel
      </button>
    </div>
  );
}
