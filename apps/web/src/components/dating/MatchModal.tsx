"use client";

import { Heart } from "lucide-react";
import { Button } from "@/components";

export type MatchModalProps = {
  name: string | null;
  photo: string | null;
  conversationId: string | null;
  onSayHi: (conversationId: string) => void;
  onDismiss: () => void;
};

/** "It's a match!" — shown from the deck AND from a like-back in Likes. */
export function MatchModal({ name, photo, conversationId, onSayHi, onDismiss }: MatchModalProps) {
  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-6 backdrop-blur-sm"
      role="dialog"
      aria-modal="true"
      aria-label="It's a match"
    >
      <div className="w-full max-w-xs rounded-3xl bg-surface p-6 text-center shadow-elevated animate-scale-in">
        <div className="accent-gradient mx-auto flex h-20 w-20 items-center justify-center overflow-hidden rounded-full shadow-accent-glow">
          {photo ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={photo} alt="" className="h-full w-full object-cover" />
          ) : (
            <Heart className="h-9 w-9 text-white" aria-hidden />
          )}
        </div>
        <h2 className="mt-4 text-lg font-semibold text-fg">
          It&apos;s a match{name ? ` with ${name}` : ""}!
        </h2>
        <p className="mt-1 text-sm text-muted">You liked each other. Say something.</p>
        <div className="mt-5 flex flex-col gap-2">
          {conversationId && (
            <Button type="button" onClick={() => onSayHi(conversationId)}>
              Say hi
            </Button>
          )}
          <Button type="button" variant="ghost" onClick={onDismiss}>
            Keep swiping
          </Button>
        </div>
      </div>
    </div>
  );
}
