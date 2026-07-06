"use client";

import { useEffect, useRef, useState } from "react";
import { Mic, MicOff, PhoneOff, Video, VideoOff } from "lucide-react";
import type { LocalVideoTrack, RemoteVideoTrack } from "livekit-client";
import { Avatar } from "@/components";

export type InCallScreenProps = {
  peerName: string;
  peerId: string;
  /** True while connecting to the room (before media flows); shows "Connecting…" instead of the timer. */
  connecting: boolean;
  muted: boolean;
  onToggleMute: () => void;
  onHangup: () => void;
  /** Phase-2 video: when false this is a voice call and the UI is byte-for-byte the original. */
  video: boolean;
  /** Our own camera track (self-view PiP) — null when off / not yet published. */
  localVideoTrack: LocalVideoTrack | null;
  /** The peer's camera track (full-screen) — null until they publish / when they turn it off. */
  remoteVideoTrack: RemoteVideoTrack | null;
  cameraOn: boolean;
  onToggleCamera: () => void;
};

function formatElapsed(totalSeconds: number) {
  const m = Math.floor(totalSeconds / 60)
    .toString()
    .padStart(2, "0");
  const s = (totalSeconds % 60).toString().padStart(2, "0");
  return `${m}:${s}`;
}

/** Active-call screen: voice = avatar + timer + mute + hangup (unchanged); video = full-screen remote +
 *  self-view PiP + mute/camera/hangup. Owns the <video> elements; the remote AUDIO sink lives in the
 *  provider and is never touched here. */
export function InCallScreen({
  peerName,
  peerId,
  connecting,
  muted,
  onToggleMute,
  onHangup,
  video,
  localVideoTrack,
  remoteVideoTrack,
  cameraOn,
  onToggleCamera
}: InCallScreenProps) {
  const [elapsed, setElapsed] = useState(0);
  const startedAt = useRef<number | null>(null);
  const remoteVideoRef = useRef<HTMLVideoElement>(null);
  const localVideoRef = useRef<HTMLVideoElement>(null);

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

  // Attach the remote/local camera tracks to their <video> sinks. No-ops for voice (tracks are null).
  useEffect(() => {
    const el = remoteVideoRef.current;
    if (!el || !remoteVideoTrack) return;
    remoteVideoTrack.attach(el);
    return () => {
      remoteVideoTrack.detach(el);
    };
  }, [remoteVideoTrack]);

  useEffect(() => {
    const el = localVideoRef.current;
    if (!el || !localVideoTrack) return;
    localVideoTrack.attach(el);
    return () => {
      localVideoTrack.detach(el);
    };
  }, [localVideoTrack]);

  // ---- VOICE: the original UI, unchanged --------------------------------------------------------
  if (!video) {
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

  // ---- VIDEO -------------------------------------------------------------------------------------
  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label={`Video call with ${peerName}`}
      className="fixed inset-0 z-[60] bg-black animate-fade-in"
    >
      {/* Remote camera, full-screen. Always mounted so its ref is stable for attach. */}
      <video
        ref={remoteVideoRef}
        autoPlay
        playsInline
        className="absolute inset-0 h-full w-full object-cover"
      />

      {/* Placeholder while the peer has no video (connecting / camera off). */}
      {!remoteVideoTrack && (
        <div className="absolute inset-0 flex flex-col items-center justify-center gap-4 bg-black/85 text-center">
          <Avatar id={peerId} name={peerName} size="lg" />
          <p className="text-sm font-medium text-white/70" aria-live="polite">
            {connecting ? <span className="animate-pulse">Connecting…</span> : "Camera off"}
          </p>
        </div>
      )}

      {/* Top overlay: peer name + timer. */}
      <div className="absolute inset-x-0 top-0 bg-gradient-to-b from-black/70 to-transparent p-5 pt-[calc(env(safe-area-inset-top)+1rem)]">
        <h2 className="text-lg font-semibold text-white drop-shadow">{peerName}</h2>
        <p className="mt-0.5 text-xs font-medium text-white/80 drop-shadow" aria-live="polite">
          {connecting ? "Connecting…" : <span className="tabular-nums">{formatElapsed(elapsed)}</span>}
        </p>
      </div>

      {/* Local self-view PiP (mirrored). Hidden when the camera is off / no track. */}
      {cameraOn && localVideoTrack && (
        <video
          ref={localVideoRef}
          autoPlay
          playsInline
          muted
          className="absolute bottom-28 right-4 aspect-[3/4] w-[28vw] max-w-[160px] scale-x-[-1] rounded-2xl border border-white/20 object-cover shadow-lg"
        />
      )}

      {/* Controls: Mute · Camera · Hang up. */}
      <div className="absolute inset-x-0 bottom-0 flex items-center justify-center gap-8 bg-gradient-to-t from-black/70 to-transparent p-8 pb-[calc(env(safe-area-inset-bottom)+2rem)]">
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
          onClick={onToggleCamera}
          disabled={connecting}
          className="flex flex-col items-center gap-2 disabled:opacity-50"
          aria-pressed={cameraOn}
          aria-label={cameraOn ? "Turn camera off" : "Turn camera on"}
        >
          <span
            className={`flex h-14 w-14 items-center justify-center rounded-full text-white shadow-lg transition-transform active:scale-95 ${
              cameraOn ? "bg-white/10" : "bg-white/25"
            }`}
          >
            {cameraOn ? <Video className="h-6 w-6" aria-hidden /> : <VideoOff className="h-6 w-6" aria-hidden />}
          </span>
          <span className="text-xs font-medium text-white/80">Camera</span>
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
