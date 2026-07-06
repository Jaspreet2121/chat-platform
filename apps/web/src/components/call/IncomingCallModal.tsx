"use client";

import { Phone, PhoneOff } from "lucide-react";
import { Avatar } from "@/components";

export type IncomingCallModalProps = {
  callerName: string;
  callerId: string;
  onAccept: () => void;
  onReject: () => void;
};

/**
 * The "WhatsApp ring" for an inbound call. Full-screen overlay so it can't be missed on any chat screen.
 * Accept is the required user gesture that unlocks mic + audio autoplay (the provider connects on tap).
 */
export function IncomingCallModal({ callerName, callerId, onAccept, onReject }: IncomingCallModalProps) {
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
          <Avatar id={callerId} name={callerName} size="lg" />
        </span>
        <div>
          <p className="text-sm font-medium uppercase tracking-wide text-white/70">Incoming voice call</p>
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
