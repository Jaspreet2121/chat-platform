"use client";

import { PhoneOff } from "lucide-react";
import { Avatar } from "@/components";
import { useUserProfile } from "../chat/useUserProfile";

export type OutgoingCallScreenProps = {
  calleeName: string;
  calleeId: string;
  onCancel: () => void;
};

/** Shown after `call:invite` while the callee's phone rings — name, "Ringing…", and Cancel. */
export function OutgoingCallScreen({ calleeName, calleeId, onCancel }: OutgoingCallScreenProps) {
  // The callee's cached profile (the caller started from a conversation → already fetched; cache hit, no
  // round-trip while ringing). Falls back to initials when absent / not yet loaded.
  const profile = useUserProfile(calleeId);

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label={`Calling ${calleeName}`}
      className="fixed inset-0 z-[60] flex flex-col items-center justify-between bg-black/70 p-8 backdrop-blur-md animate-fade-in"
    >
      <div className="flex flex-1 flex-col items-center justify-center gap-5 text-center">
        <Avatar id={calleeId} name={calleeName} imageUrl={profile?.avatar_url} size="lg" />
        <div>
          <h2 className="text-2xl font-semibold text-white">{calleeName}</h2>
          <p className="mt-1 text-sm font-medium text-white/70">
            Ringing<span className="animate-pulse">…</span>
          </p>
        </div>
      </div>

      <button
        type="button"
        onClick={onCancel}
        className="flex flex-col items-center gap-2"
        aria-label="Cancel call"
      >
        <span className="flex h-16 w-16 items-center justify-center rounded-full bg-red-500 text-white shadow-lg transition-transform active:scale-95">
          <PhoneOff className="h-7 w-7" aria-hidden />
        </span>
        <span className="text-xs font-medium text-white/80">Cancel</span>
      </button>
    </div>
  );
}
