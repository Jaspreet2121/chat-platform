"use client";

import { useEffect, useRef, useState } from "react";
import { Mic, MicOff, PhoneOff } from "lucide-react";
import { Avatar } from "@/components";

export type InCallScreenProps = {
  peerName: string;
  peerId: string;
  /** True while connecting to the room (before media flows); shows "Connecting…" instead of the timer. */
  connecting: boolean;
  muted: boolean;
  onToggleMute: () => void;
  onHangup: () => void;
};

function formatElapsed(totalSeconds: number) {
  const m = Math.floor(totalSeconds / 60)
    .toString()
    .padStart(2, "0");
  const s = (totalSeconds % 60).toString().padStart(2, "0");
  return `${m}:${s}`;
}

/** Active-call screen: peer, a running call timer (starts once connected), Mute toggle, and Hang up. */
export function InCallScreen({
  peerName,
  peerId,
  connecting,
  muted,
  onToggleMute,
  onHangup
}: InCallScreenProps) {
  const [elapsed, setElapsed] = useState(0);
  const startedAt = useRef<number | null>(null);

  // Start the timer the moment we're connected (not while still connecting).
  useEffect(() => {
    if (connecting) return;
    if (startedAt.current === null) startedAt.current = Date.now();
    const id = setInterval(() => {
      if (startedAt.current !== null) {
        setElapsed(Math.floor((Date.now() - startedAt.current) / 1000));
      }
    }, 1000);
    return () => clearInterval(id);
  }, [connecting]);

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label={`In call with ${peerName}`}
      className="fixed inset-0 z-[60] flex flex-col items-center justify-between bg-black/80 p-8 backdrop-blur-md animate-fade-in"
    >
      <div className="flex flex-1 flex-col items-center justify-center gap-5 text-center">
        <Avatar id={peerId} name={peerName} size="lg" />
        <div>
          <h2 className="text-2xl font-semibold text-white">{peerName}</h2>
          <p className="mt-1 text-sm font-medium text-white/70" aria-live="polite">
            {connecting ? (
              <span className="animate-pulse">Connecting…</span>
            ) : (
              <span className="tabular-nums">{formatElapsed(elapsed)}</span>
            )}
          </p>
        </div>
      </div>

      <div className="flex w-full max-w-xs items-center justify-center gap-10">
        <button
          type="button"
          onClick={onToggleMute}
          disabled={connecting}
          className="flex flex-col items-center gap-2 disabled:opacity-50"
          aria-pressed={muted}
          aria-label={muted ? "Unmute microphone" : "Mute microphone"}
        >
          <span
            className={`flex h-14 w-14 items-center justify-center rounded-full text-white shadow-lg transition-transform active:scale-95 ${
              muted ? "bg-white/25" : "bg-white/10"
            }`}
          >
            {muted ? <MicOff className="h-6 w-6" aria-hidden /> : <Mic className="h-6 w-6" aria-hidden />}
          </span>
          <span className="text-xs font-medium text-white/80">{muted ? "Unmute" : "Mute"}</span>
        </button>

        <button
          type="button"
          onClick={onHangup}
          className="flex flex-col items-center gap-2"
          aria-label="Hang up"
        >
          <span className="flex h-16 w-16 items-center justify-center rounded-full bg-red-500 text-white shadow-lg transition-transform active:scale-95">
            <PhoneOff className="h-7 w-7" aria-hidden />
          </span>
          <span className="text-xs font-medium text-white/80">End</span>
        </button>
      </div>
    </div>
  );
}
