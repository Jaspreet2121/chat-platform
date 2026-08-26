"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { ChevronLeft, ChevronRight, Heart, SlidersHorizontal, X } from "lucide-react";
import { Button } from "@/components";
import { EmptyState } from "@/components/chat";
import { ApiRequestError, type DatingCard, type DatingSwipeResult } from "@/lib/api";
import { sharedChips } from "@/lib/dating";
import { cn } from "@/lib/cn";

export type DatingDeckProps = {
  cards: DatingCard[];
  /** key → label from the tag catalog (106); unknown keys render as their key. */
  tagLabels: Record<string, string>;
  /** Swipe the TOP card. Resolves with the server result so the match modal can fire. */
  onSwipe: (card: DatingCard, action: "like" | "pass") => Promise<DatingSwipeResult>;
  onOpenPrefs: () => void;
  loading: boolean;
};

/**
 * The card stack. Buttons + keyboard (← pass, → like) are the contract; on top of them a tiny
 * dependency-free pointer drag (translate + rotate, threshold 96px) — pointer events only, no
 * library. 429 renders as a gentle cooldown note, not an error wall.
 */
export function DatingDeck({ cards, tagLabels, onSwipe, onOpenPrefs, loading }: DatingDeckProps) {
  const top = cards[0] ?? null;
  const [busy, setBusy] = useState(false);
  const [cooldown, setCooldown] = useState<string | null>(null);

  const act = useCallback(
    async (action: "like" | "pass") => {
      if (!top || busy) return;
      setBusy(true);
      setCooldown(null);
      try {
        await onSwipe(top, action);
      } catch (error) {
        if (error instanceof ApiRequestError && error.status === 429) {
          setCooldown("Easy there — give it a few seconds and swipe on.");
        } else {
          setCooldown(error instanceof Error ? error.message : "That didn't go through — try again.");
        }
      } finally {
        setBusy(false);
      }
    },
    [top, busy, onSwipe]
  );

  // Keyboard: ← pass · → like (ignored while typing in an input).
  useEffect(() => {
    function onKey(event: KeyboardEvent) {
      const target = event.target as HTMLElement | null;
      if (target && ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName)) return;
      if (event.key === "ArrowLeft") void act("pass");
      if (event.key === "ArrowRight") void act("like");
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [act]);

  if (!top) {
    return loading ? (
      <div className="flex h-full items-center justify-center text-sm text-muted">Finding people…</div>
    ) : (
      <div className="flex h-full flex-col items-center justify-center">
        <EmptyState
          icon={<Heart className="h-6 w-6" aria-hidden />}
          title="No one new nearby"
          hint="Widen your distance or age range to see more people."
        />
        <Button type="button" variant="ghost" size="sm" onClick={onOpenPrefs}>
          <SlidersHorizontal className="mr-1.5 h-4 w-4" aria-hidden />
          Adjust preferences
        </Button>
      </div>
    );
  }

  return (
    <div className="mx-auto flex h-full w-full max-w-sm flex-col px-4 py-4">
      <div className="relative flex-1">
        {/* Peek of the next card. */}
        {cards[1] && (
          <div className="absolute inset-0 translate-y-2 scale-[0.97] rounded-3xl bg-elevated shadow-subtle" aria-hidden />
        )}
        {/* key: all per-card state (photo index, bio, drag) resets WITH the card — no effects. */}
        <TopCard
          key={top.user_id}
          card={top}
          tagLabels={tagLabels}
          onCommit={(action) => void act(action)}
        />
      </div>

      {cooldown && (
        <p className="mt-3 text-center text-xs text-muted" role="status">
          {cooldown}
        </p>
      )}

      <div className="mt-4 flex items-center justify-center gap-8">
        <button
          type="button"
          onClick={() => void act("pass")}
          disabled={busy}
          aria-label="Pass"
          className="flex h-14 w-14 items-center justify-center rounded-full border border-border bg-surface text-red-400 shadow-subtle transition-transform hover:scale-105 active:scale-95"
        >
          <X className="h-7 w-7" aria-hidden />
        </button>
        <button
          type="button"
          onClick={() => void act("like")}
          disabled={busy}
          aria-label="Like"
          className="accent-gradient flex h-16 w-16 items-center justify-center rounded-full text-white shadow-accent-glow transition-transform hover:scale-105 active:scale-95"
        >
          <Heart className="h-8 w-8" aria-hidden />
        </button>
      </div>
      <p className="mt-2 text-center text-[11px] text-faint">← pass · → like</p>
    </div>
  );
}

/** The visible top card. Mounted with key={card.user_id}, so photo index / bio / drag state are
 *  born fresh with each card — the React-idiomatic reset, no setState-in-effect. */
function TopCard({
  card,
  tagLabels,
  onCommit
}: {
  card: DatingCard;
  tagLabels: Record<string, string>;
  onCommit: (action: "like" | "pass") => void;
}) {
  const [photoIndex, setPhotoIndex] = useState(0);
  const [bioOpen, setBioOpen] = useState(false);
  const [drag, setDrag] = useState<{ dx: number; dy: number } | null>(null);
  const dragStart = useRef<{ x: number; y: number } | null>(null);

  const photos = card.photos.length > 0 ? card.photos : [null];
  const dx = drag?.dx ?? 0;
  const leaning = Math.abs(dx) > 40 ? (dx > 0 ? "like" : "pass") : null;

  return (
    <div
      className="absolute inset-0 touch-none overflow-hidden rounded-3xl bg-elevated shadow-elevated select-none"
      style={{
        transform: drag
          ? `translate(${drag.dx}px, ${drag.dy}px) rotate(${drag.dx / 18}deg)`
          : undefined,
        transition: drag ? "none" : "transform 180ms ease-out"
      }}
      onPointerDown={(event) => {
        dragStart.current = { x: event.clientX, y: event.clientY };
        (event.target as HTMLElement).setPointerCapture?.(event.pointerId);
      }}
      onPointerMove={(event) => {
        if (!dragStart.current) return;
        setDrag({ dx: event.clientX - dragStart.current.x, dy: event.clientY - dragStart.current.y });
      }}
      onPointerUp={() => {
        const delta = drag?.dx ?? 0;
        dragStart.current = null;
        setDrag(null);
        if (Math.abs(delta) > 96) onCommit(delta > 0 ? "like" : "pass");
      }}
      onPointerCancel={() => {
        dragStart.current = null;
        setDrag(null);
      }}
    >
      {photos[photoIndex] ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src={photos[photoIndex] as string}
          alt={`${card.display_name ?? "Their"} photo ${photoIndex + 1}`}
          className="h-full w-full object-cover"
          draggable={false}
        />
      ) : (
        <div className="flex h-full w-full items-center justify-center bg-brand-subtle/40 text-4xl font-semibold text-brand-hover">
          {(card.display_name ?? "?").slice(0, 1)}
        </div>
      )}

      {/* Photo dots + tap zones */}
      {photos.length > 1 && (
        <>
          <div className="absolute inset-x-0 top-2 flex justify-center gap-1">
            {photos.map((_, index) => (
              <span
                key={index}
                className={cn("h-1 w-6 rounded-full", index === photoIndex ? "bg-white" : "bg-white/40")}
                aria-hidden
              />
            ))}
          </div>
          <button
            type="button"
            aria-label="Previous photo"
            onClick={() => setPhotoIndex((index) => Math.max(0, index - 1))}
            className="absolute inset-y-0 left-0 w-1/4 text-white/0 focus-visible:text-white"
          >
            <ChevronLeft className="mx-auto h-6 w-6" aria-hidden />
          </button>
          <button
            type="button"
            aria-label="Next photo"
            onClick={() => setPhotoIndex((index) => Math.min(photos.length - 1, index + 1))}
            className="absolute inset-y-0 right-0 w-1/4 text-white/0 focus-visible:text-white"
          >
            <ChevronRight className="mx-auto h-6 w-6" aria-hidden />
          </button>
        </>
      )}

      {/* Drag feedback */}
      {leaning && (
        <span
          className={cn(
            "absolute top-6 rounded-lg border-2 px-3 py-1 text-lg font-bold uppercase tracking-wide",
            leaning === "like"
              ? "left-4 -rotate-12 border-emerald-400 text-emerald-400"
              : "right-4 rotate-12 border-red-400 text-red-400"
          )}
        >
          {leaning === "like" ? "Like" : "Pass"}
        </span>
      )}

      {/* Name / age / distance / intention / common ground / bio */}
      <div className="absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/80 via-black/40 to-transparent p-4 pt-14 text-white">
        <div className="flex items-center gap-2">
          <p className="text-xl font-semibold">
            {card.display_name ?? "Someone"}
            {card.age != null && <span className="font-normal">, {card.age}</span>}
          </p>
          {card.intention && (
            <span className="rounded-full bg-white/20 px-2 py-0.5 text-[10px] font-medium backdrop-blur-sm">
              {tagLabels[card.intention] ?? card.intention}
            </span>
          )}
        </div>
        {card.distance_km != null && <p className="text-xs text-white/80">{card.distance_km} km away</p>}
        <SharedRow shared={card.shared_turn_ons} tagLabels={tagLabels} />
        {card.bio && (
          <button
            type="button"
            onClick={() => setBioOpen((open) => !open)}
            className={cn("mt-1 text-left text-sm text-white/90", !bioOpen && "line-clamp-2")}
          >
            {card.bio}
          </button>
        )}
        {bioOpen && card.turn_ons.length > 0 && (
          <div className="mt-2 flex flex-wrap gap-1.5">
            {card.turn_ons.map((key) => {
              const shared = card.shared_turn_ons.includes(key);
              return (
                <span
                  key={key}
                  className={cn(
                    "rounded-full px-2 py-0.5 text-[10px]",
                    shared
                      ? "accent-gradient font-medium text-white shadow-accent-glow"
                      : "bg-white/15 text-white/85"
                  )}
                >
                  {tagLabels[key] ?? key}
                </span>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}

/** "You both like:" — up to four highlighted chips + "+n" (nothing renders when empty). */
function SharedRow({
  shared,
  tagLabels
}: {
  shared: string[];
  tagLabels: Record<string, string>;
}) {
  const { visible, extra } = sharedChips(shared);
  if (visible.length === 0) return null;
  return (
    <div className="mt-1.5 flex flex-wrap items-center gap-1.5">
      <span className="text-[10px] uppercase tracking-wide text-white/70">You both like</span>
      {visible.map((key) => (
        <span
          key={key}
          className="accent-gradient rounded-full px-2 py-0.5 text-[10px] font-medium text-white shadow-accent-glow"
        >
          {tagLabels[key] ?? key}
        </span>
      ))}
      {extra > 0 && <span className="text-[10px] text-white/80">+{extra}</span>}
    </div>
  );
}
