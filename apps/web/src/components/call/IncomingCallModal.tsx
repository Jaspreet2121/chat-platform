"use client";

import { Lock, Phone, PhoneOff } from "lucide-react";
import { Avatar } from "@/components";

export type IncomingCallModalProps = {
  callerName: string;
  callerId: string;
  /** Presigned caller avatar carried on the ring payload; absent → the Avatar falls back to initials. */
  callerAvatarUrl?: string;
  /** Phase-2: video vs voice — only changes the label. Accept is the same gesture; the provider publishes
   *  the camera on connect because the stored ActiveCall carries type="video". */
  video: boolean;
  /** Phase-3: a group ring — tweaks the label to "Incoming group … call". */
  group?: boolean;
  /** §10: an E2EE offer rode the ring. A HINT only — the mode is settled when we open our envelope. */
  e2eeOffered?: boolean;
  onAccept: () => void;
  onReject: () => void;
};

/**
 * The "WhatsApp ring" for an inbound call. Full-screen overlay so it can't be missed on any chat screen.
 * Accept is the required user gesture that unlocks mic + audio autoplay (the provider connects on tap).
 */
export function IncomingCallModal({
  callerName,
  callerId,
  callerAvatarUrl,
  video,
  group,
  e2eeOffered,
  onAccept,
  onReject
}: IncomingCallModalProps) {
  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label={`Incoming call from ${callerName}`}
      className="fixed inset-0 z-[60] flex flex-col items-center justify-between bg-black/70 p-8 backdrop-blur-md animate-fade-in"
    >
      <div className="flex flex-1 flex-col items-center justify-center gap-5 text-center">
        <span className="relative flex">
          <span className="absolute inset-0 animate-ping rounded-full bg-white/20" aria-hidden />
          <Avatar id={callerId} name={callerName} imageUrl={callerAvatarUrl ?? null} size="lg" />
        </span>
        <div>
          {e2eeOffered ? (
            <p className="mb-1 inline-flex items-center gap-1 text-[11px] font-medium text-white/80">
              <Lock className="h-3 w-3" aria-hidden />
              End-to-end encrypted
            </p>
          ) : null}
          <p className="text-sm font-medium uppercase tracking-wide text-white/70">
            Incoming {group ? "group " : ""}{video ? "video" : "voice"} call
          </p>
          <h2 className="mt-1 text-2xl font-semibold text-white">{callerName}</h2>
        </div>
      </div>

      <div className="flex w-full max-w-xs items-center justify-between">
        <button
          type="button"
          onClick={onReject}
          className="flex flex-col items-center gap-2"
          aria-label="Reject call"
        >
          <span className="flex h-16 w-16 items-center justify-center rounded-full bg-red-500 text-white shadow-lg transition-transform active:scale-95">
            <PhoneOff className="h-7 w-7" aria-hidden />
          </span>
          <span className="text-xs font-medium text-white/80">Decline</span>
        </button>
        <button
          type="button"
          onClick={onAccept}
          className="flex flex-col items-center gap-2"
          aria-label="Accept call"
        >
          <span className="flex h-16 w-16 items-center justify-center rounded-full bg-emerald-500 text-white shadow-lg transition-transform active:scale-95">
            <Phone className="h-7 w-7" aria-hidden />
          </span>
          <span className="text-xs font-medium text-white/80">Accept</span>
        </button>
      </div>
    </div>
  );
}
