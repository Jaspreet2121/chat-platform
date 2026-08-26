"use client";

import { useState } from "react";
import { Heart, X } from "lucide-react";
import { EmptyState } from "@/components/chat";
import type { DatingCard, DatingSwipeResult } from "@/lib/api";
import { sharedChips } from "@/lib/dating";

export type DatingLikesProps = {
  cards: DatingCard[];
  tagLabels: Record<string, string>;
  loaded: boolean;
  /** Like back (may match) or pass (hides them from this list forever; they're never told). */
  onAct: (card: DatingCard, action: "like" | "pass") => Promise<DatingSwipeResult>;
};

/** People who liked me — a card grid; acting goes through the normal swipe endpoint. */
export function DatingLikes({ cards, tagLabels, loaded, onAct }: DatingLikesProps) {
  const [busyId, setBusyId] = useState<string | null>(null);

  if (loaded && cards.length === 0) {
    return (
      <EmptyState
        icon={<Heart className="h-6 w-6" aria-hidden />}
        title="No likes yet"
        hint="When someone likes you, they show up here."
      />
    );
  }

  async function act(card: DatingCard, action: "like" | "pass") {
    setBusyId(card.user_id);
    try {
      await onAct(card, action);
    } finally {
      setBusyId(null);
    }
  }

  return (
    <div className="grid grid-cols-2 gap-3 p-4 sm:grid-cols-3">
      {cards.map((card) => (
        <div key={card.user_id} className="overflow-hidden rounded-2xl bg-elevated shadow-subtle">
          <div className="relative aspect-[3/4]">
            {card.photos[0] ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={card.photos[0]} alt="" className="h-full w-full object-cover" />
            ) : (
              <div className="flex h-full w-full items-center justify-center bg-brand-subtle/40 text-2xl font-semibold text-brand-hover">
                {(card.display_name ?? "?").slice(0, 1)}
              </div>
            )}
            <div className="absolute inset-x-0 bottom-0 bg-gradient-to-t from-black/75 to-transparent p-2 text-white">
              <p className="truncate text-sm font-medium">
                {card.display_name ?? "Someone"}
                {card.age != null && <span className="font-normal">, {card.age}</span>}
              </p>
              {card.intention && (
                <p className="truncate text-[10px] text-white/80">
                  {tagLabels[card.intention] ?? card.intention}
                </p>
              )}
              {card.distance_km != null && (
                <p className="text-[10px] text-white/75">{card.distance_km} km away</p>
              )}
              <LikesSharedRow shared={card.shared_turn_ons} tagLabels={tagLabels} />
            </div>
          </div>
          <div className="flex">
            <button
              type="button"
              onClick={() => void act(card, "pass")}
              disabled={busyId === card.user_id}
              aria-label={`Pass on ${card.display_name ?? "them"}`}
              className="flex flex-1 items-center justify-center py-2 text-red-400 hover:bg-red-500/10"
            >
              <X className="h-5 w-5" aria-hidden />
            </button>
            <button
              type="button"
              onClick={() => void act(card, "like")}
              disabled={busyId === card.user_id}
              aria-label={`Like ${card.display_name ?? "them"} back`}
              className="flex flex-1 items-center justify-center py-2 text-brand hover:bg-brand-subtle/40"
            >
              <Heart className="h-5 w-5" aria-hidden />
            </button>
          </div>
        </div>
      ))}
    </div>
  );
}

function LikesSharedRow({
  shared,
  tagLabels
}: {
  shared: string[];
  tagLabels: Record<string, string>;
}) {
  const { visible, extra } = sharedChips(shared, 2);
  if (visible.length === 0) return null;
  return (
    <p className="mt-0.5 flex flex-wrap items-center gap-1">
      {visible.map((key) => (
        <span
          key={key}
          className="accent-gradient rounded-full px-1.5 py-0.5 text-[9px] font-medium text-white"
        >
          {tagLabels[key] ?? key}
        </span>
      ))}
      {extra > 0 && <span className="text-[9px] text-white/80">+{extra}</span>}
    </p>
  );
}
