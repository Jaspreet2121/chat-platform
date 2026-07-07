"use client";

import { useEffect, useRef, useState } from "react";
import { Mic, MicOff, PhoneOff, SwitchCamera, Video, VideoOff } from "lucide-react";
import type { LocalVideoTrack, RemoteVideoTrack } from "livekit-client";
import { Avatar } from "@/components";
import { cn } from "@/lib/cn";
import { useUserProfile } from "../chat/useUserProfile";

export type GroupTile = {
  /** LiveKit identity = the participant's user_id. */
  identity: string;
  videoTrack: RemoteVideoTrack | null;
};

export type GroupInCallScreenProps = {
  title: string;
  connecting: boolean;
  video: boolean;
  muted: boolean;
  onToggleMute: () => void;
  onHangup: () => void;
  cameraOn: boolean;
  onToggleCamera: () => void;
  canSwitchCamera: boolean;
  onSwitchCamera: () => void;
  /** Remote participants (excluding me). */
  participants: GroupTile[];
  /** Me. */
  currentUserId?: string;
  localVideoTrack: LocalVideoTrack | null;
};

function formatElapsed(totalSeconds: number) {
  const m = Math.floor(totalSeconds / 60).toString().padStart(2, "0");
  const s = (totalSeconds % 60).toString().padStart(2, "0");
  return `${m}:${s}`;
}

/** One grid cell: the participant's camera if published, else their avatar. `mirror` for the self view. */
function Tile({
  identity,
  videoTrack,
  mirror,
  selfLabel
}: {
  identity: string;
  videoTrack: LocalVideoTrack | RemoteVideoTrack | null;
  mirror?: boolean;
  selfLabel?: string;
}) {
  const profile = useUserProfile(selfLabel ? null : identity);
  const ref = useRef<HTMLVideoElement>(null);
  const name = selfLabel ?? profile?.display_name?.trim() ?? `${identity.slice(0, 8)}…`;

  useEffect(() => {
    const el = ref.current;
    if (!el || !videoTrack) return;
    videoTrack.attach(el);
    return () => {
      videoTrack.detach(el);
    };
  }, [videoTrack]);

  return (
    <div className="relative min-h-0 overflow-hidden rounded-2xl bg-white/5 ring-1 ring-white/10">
      <video
        ref={ref}
        autoPlay
        playsInline
        muted
        className={cn("h-full w-full object-cover", mirror && "scale-x-[-1]", !videoTrack && "hidden")}
      />
      {!videoTrack && (
        <div className="flex h-full w-full items-center justify-center">
          <Avatar id={identity} name={name} imageUrl={selfLabel ? undefined : profile?.avatar_url} size="lg" />
        </div>
      )}
      <span className="absolute bottom-1.5 left-2 max-w-[85%] truncate rounded bg-black/40 px-1.5 py-0.5 text-xs font-medium text-white/90">
        {name}
      </span>
    </div>
  );
}

/** Active group-call screen: an equal grid of participant tiles (self + remotes) + a control row. */
export function GroupInCallScreen({
  title,
  connecting,
  video,
  muted,
  onToggleMute,
  onHangup,
  cameraOn,
  onToggleCamera,
  canSwitchCamera,
  onSwitchCamera,
  participants,
  currentUserId,
  localVideoTrack
}: GroupInCallScreenProps) {
  const [elapsed, setElapsed] = useState(0);
  const startedAt = useRef<number | null>(null);

  useEffect(() => {
    if (connecting) return;
    if (startedAt.current === null) startedAt.current = Date.now();
    const id = setInterval(() => {
      if (startedAt.current !== null) setElapsed(Math.floor((Date.now() - startedAt.current) / 1000));
    }, 1000);
    return () => clearInterval(id);
  }, [connecting]);

  // Self tile first, then remotes. Column count keeps tiles roughly square.
  const tileCount = participants.length + 1;
  const cols = Math.min(Math.ceil(Math.sqrt(tileCount)), 4);

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label={`Group call: ${title}`}
      className="fixed inset-0 z-[60] flex flex-col bg-black animate-fade-in"
    >
      {/* Top: group name + timer / status. */}
      <div className="shrink-0 px-5 pb-2 pt-[calc(env(safe-area-inset-top)+1rem)] text-center">
        <h2 className="truncate text-base font-semibold text-white drop-shadow">{title}</h2>
        <p className="mt-0.5 text-xs font-medium text-white/70" aria-live="polite">
          {connecting ? (
            <span className="animate-pulse">Connecting…</span>
          ) : (
            <span className="tabular-nums">
              {formatElapsed(elapsed)} · {tileCount} in call
            </span>
          )}
        </p>
      </div>

      {/* Grid. */}
      <div
        className="grid min-h-0 flex-1 gap-2 px-3 pb-2"
        style={{ gridTemplateColumns: `repeat(${cols}, minmax(0, 1fr))` }}
      >
        <Tile
          identity={currentUserId ?? "me"}
          videoTrack={cameraOn ? localVideoTrack : null}
          mirror
          selfLabel="You"
        />
        {participants.map((p) => (
          <Tile key={p.identity} identity={p.identity} videoTrack={p.videoTrack} />
        ))}
      </div>

      {/* Controls: Mute · [Switch] · [Camera] · Leave. */}
      <div className="flex shrink-0 items-center justify-center gap-6 bg-gradient-to-t from-black/70 to-transparent p-6 pb-[calc(env(safe-area-inset-bottom)+1.5rem)]">
        <button
          type="button"
          onClick={onToggleMute}
          disabled={connecting}
          className="flex flex-col items-center gap-1.5 disabled:opacity-50"
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

        {video && canSwitchCamera && (
          <button
            type="button"
            onClick={onSwitchCamera}
            disabled={connecting || !cameraOn}
            className="flex flex-col items-center gap-1.5 disabled:opacity-50"
            aria-label="Switch camera"
          >
            <span className="flex h-14 w-14 items-center justify-center rounded-full bg-white/10 text-white shadow-lg transition-transform active:scale-95">
              <SwitchCamera className="h-6 w-6" aria-hidden />
            </span>
            <span className="text-xs font-medium text-white/80">Switch</span>
          </button>
        )}

        {video && (
          <button
            type="button"
            onClick={onToggleCamera}
            disabled={connecting}
            className="flex flex-col items-center gap-1.5 disabled:opacity-50"
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
        )}

        <button
          type="button"
          onClick={onHangup}
          className="flex flex-col items-center gap-1.5"
          aria-label="Leave call"
        >
          <span className="flex h-16 w-16 items-center justify-center rounded-full bg-red-500 text-white shadow-lg transition-transform active:scale-95">
            <PhoneOff className="h-7 w-7" aria-hidden />
          </span>
          <span className="text-xs font-medium text-white/80">Leave</span>
        </button>
      </div>
    </div>
  );
}
