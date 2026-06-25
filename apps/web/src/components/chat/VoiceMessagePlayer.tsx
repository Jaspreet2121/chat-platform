"use client";

import { type PointerEvent as ReactPointerEvent, useEffect, useMemo, useRef, useState } from "react";
import { Loader2, Mic, Pause, Play } from "lucide-react";
import { cn } from "@/lib/cn";

const BAR_COUNT = 40;

export type VoiceMessagePlayerProps = {
  /** Resolved signed audio URL, or null while it's still being resolved (loading state). */
  url: string | null;
  isOwn: boolean;
  /** Stable per-message seed so the synthetic waveform shape never changes between renders. */
  seed: string;
  /** Called when the <audio> errors (e.g. an expired signed URL) so the parent can re-resolve / fall back. */
  onError: () => void;
};

// A custom voice-message player: play/pause, a synthetic waveform that fills with playback progress, a
// gentle equalizer pulse while playing, duration/elapsed, and click/drag-to-seek. Uses a hidden <audio>
// ref (not native controls). Colors inherit the parent bubble's text color (currentColor), so it reads
// on any bubble (green/blue on light, tinted glass on dark) — `isOwn` is no longer needed for styling.
export function VoiceMessagePlayer({ url, seed, onError }: VoiceMessagePlayerProps) {
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const waveRef = useRef<HTMLDivElement | null>(null);
  const rafRef = useRef<number | null>(null);
  const fixingDurationRef = useRef(false);
  const scrubbingRef = useRef(false);

  const [isPlaying, setIsPlaying] = useState(false);
  const [duration, setDuration] = useState(0);
  const [currentTime, setCurrentTime] = useState(0);

  // Deterministic, stable waveform shape (a voice-like envelope: louder mid, tapering ends).
  const bars = useMemo(() => synthWaveform(seed, BAR_COUNT), [seed]);

  const hasDuration = Number.isFinite(duration) && duration > 0;
  const progress = hasDuration ? Math.min(1, currentTime / duration) : 0;
  const displaySeconds = isPlaying || currentTime > 0 ? currentTime : duration;

  // Smooth progress via rAF while playing (timeupdate fires too coarsely for a fluid waveform fill).
  useEffect(() => {
    if (!isPlaying) return;
    const tick = () => {
      const audio = audioRef.current;
      if (audio) setCurrentTime(audio.currentTime);
      rafRef.current = requestAnimationFrame(tick);
    };
    rafRef.current = requestAnimationFrame(tick);
    return () => {
      if (rafRef.current) cancelAnimationFrame(rafRef.current);
      rafRef.current = null;
    };
  }, [isPlaying]);

  // Cleanup: stop playback + cancel the animation frame on unmount. Capture the element up front (the
  // <audio> ref is stable for the component's life) so the cleanup doesn't read a possibly-changed ref.
  useEffect(() => {
    const audio = audioRef.current;
    return () => {
      if (rafRef.current) cancelAnimationFrame(rafRef.current);
      audio?.pause();
    };
  }, []);

  function togglePlay() {
    const audio = audioRef.current;
    if (!audio || !url) return;
    if (audio.paused) {
      audio
        .play()
        .then(() => setIsPlaying(true))
        .catch(() => onError());
    } else {
      audio.pause();
      setIsPlaying(false);
    }
  }

  // MediaRecorder webm/ogg blobs often report duration === Infinity until the browser scans the file;
  // seeking past the end forces it to compute the real duration (then `durationchange` fires finite).
  function handleLoadedMetadata() {
    const audio = audioRef.current;
    if (!audio) return;
    if (Number.isFinite(audio.duration) && audio.duration > 0) {
      setDuration(audio.duration);
    } else {
      fixingDurationRef.current = true;
      try {
        audio.currentTime = 1e101;
      } catch {
        // ignore — some browsers reject the out-of-range seek; duration stays unknown but playback works
      }
    }
  }

  function handleDurationChange() {
    const audio = audioRef.current;
    if (!audio || !Number.isFinite(audio.duration) || audio.duration <= 0) return;
    setDuration(audio.duration);
    if (fixingDurationRef.current) {
      fixingDurationRef.current = false;
      audio.currentTime = 0;
      setCurrentTime(0);
    }
  }

  function handleEnded() {
    setIsPlaying(false);
    setCurrentTime(0);
    if (audioRef.current) audioRef.current.currentTime = 0;
  }

  function seekToClientX(clientX: number) {
    const wave = waveRef.current;
    const audio = audioRef.current;
    if (!wave || !audio || !hasDuration) return;
    const rect = wave.getBoundingClientRect();
    const fraction = Math.min(1, Math.max(0, (clientX - rect.left) / rect.width));
    const next = fraction * duration;
    audio.currentTime = next;
    setCurrentTime(next);
  }

  function handlePointerDown(event: ReactPointerEvent<HTMLDivElement>) {
    if (!hasDuration) return;
    scrubbingRef.current = true;
    event.currentTarget.setPointerCapture(event.pointerId);
    seekToClientX(event.clientX);
  }

  function handlePointerMove(event: ReactPointerEvent<HTMLDivElement>) {
    if (scrubbingRef.current) seekToClientX(event.clientX);
  }

  function endScrub(event: ReactPointerEvent<HTMLDivElement>) {
    scrubbingRef.current = false;
    try {
      event.currentTarget.releasePointerCapture(event.pointerId);
    } catch {
      // pointer already released
    }
  }

  const isLoading = !url;

  return (
    // No own surface here — the parent message bubble IS the surface. We render the player directly on
    // it (single clean box), capped to a compact width so short clips aren't oversized.
    <div className="flex w-[240px] max-w-full items-center gap-3">

      <audio
        ref={audioRef}
        src={url ?? undefined}
        preload="metadata"
        onLoadStart={() => {
          // Fires on (re)load — incl. an expiry re-resolution swapping the src — so reset transport.
          setIsPlaying(false);
          setCurrentTime(0);
        }}
        onLoadedMetadata={handleLoadedMetadata}
        onDurationChange={handleDurationChange}
        onEnded={handleEnded}
        onError={onError}
      />

      <button
        type="button"
        onClick={togglePlay}
        disabled={isLoading}
        aria-label={isPlaying ? "Pause voice message" : "Play voice message"}
        className={cn(
          // Inherits the bubble's text color; a subtle wash circle that works on any bubble surface.
          "grid h-10 w-10 shrink-0 place-items-center rounded-full bg-black/10 text-current",
          "transition-colors duration-200 hover:bg-black/15 disabled:opacity-60",
          "dark:bg-white/15 dark:hover:bg-white/20"
        )}
      >
        {isLoading ? (
          <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
        ) : isPlaying ? (
          <Pause className="h-5 w-5" aria-hidden />
        ) : (
          <Play className="h-5 w-5 translate-x-[1px]" aria-hidden />
        )}
      </button>

      <div className="flex min-w-0 flex-1 flex-col gap-1.5">
        <div
          ref={waveRef}
          onPointerDown={handlePointerDown}
          onPointerMove={handlePointerMove}
          onPointerUp={endScrub}
          onPointerCancel={endScrub}
          className={cn(
            "flex h-8 items-center gap-[2px]",
            hasDuration ? "cursor-pointer" : "cursor-default"
          )}
        >
          {bars.map((height, index) => {
            const played = index / BAR_COUNT < progress;
            return (
              <span
                key={index}
                aria-hidden
                style={{
                  height: `${Math.round(height * 100)}%`,
                  animationDelay: `${(index % 8) * 90}ms`
                }}
                className={cn(
                  // Inherits the bubble's text color: played bars solid, unplayed dimmed.
                  "min-w-0 flex-1 rounded-full bg-current transition-opacity duration-150",
                  played ? "opacity-100" : "opacity-30",
                  isPlaying && "animate-voice-bar"
                )}
              />
            );
          })}
        </div>

        <div className="flex items-center gap-1 text-[11px] text-current opacity-70">
          <Mic className="h-3 w-3 shrink-0" aria-hidden />
          <span className="tabular-nums">{formatClock(displaySeconds)}</span>
        </div>
      </div>
    </div>
  );
}

// mm:ss; guards the Infinity/NaN that webm blobs report before duration is resolved.
function formatClock(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00";
  const total = Math.floor(seconds);
  const mins = Math.floor(total / 60);
  const secs = total % 60;
  return `${mins}:${secs.toString().padStart(2, "0")}`;
}

// Deterministic synthetic waveform from a stable seed: a voice-like envelope (peaks in the middle,
// tapering at the ends) with seeded per-bar variation, so the shape is identical on every render.
function synthWaveform(seed: string, count: number): number[] {
  const rand = mulberry32(hashString(seed));
  return Array.from({ length: count }, (_, i) => {
    const envelope = Math.sin((i / (count - 1)) * Math.PI); // 0 at ends, 1 in the middle
    const variation = 0.35 + rand() * 0.65;
    return Math.max(0.14, Math.min(1, variation * (0.45 + 0.55 * envelope)));
  });
}

function hashString(value: string): number {
  let hash = 2166136261;
  for (let i = 0; i < value.length; i++) {
    hash ^= value.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}

function mulberry32(seed: number): () => number {
  let state = seed;
  return () => {
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
