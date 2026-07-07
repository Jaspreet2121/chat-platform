"use client";

import { useEffect } from "react";
import { Phone, Video } from "lucide-react";
import { fetchOngoingGroupCall } from "@/lib/api";
import { useCall } from "./CallProvider";

export type GroupCallBannerProps = {
  conversationId: string;
  /** Group name — becomes the in-call header title when we join. */
  title: string;
};

/**
 * A slim "Group call in progress · Join" strip under the ChatHeader of a GROUP thread when that group has
 * an ongoing call the viewer isn't in. Two sources, one state: a thread-open fetch SEEDS the provider's
 * ongoing-call map (covers a call started before we opened the thread), and live call:group_incoming /
 * group_ended events keep it fresh. Reads the single map value, so it hides the instant the call ends or
 * we join it (the provider returns null for a call we're already in).
 */
export function GroupCallBanner({ conversationId, title }: GroupCallBannerProps) {
  const { ongoingGroupCall, joinGroupCall, primeOngoingGroupCall } = useCall();

  useEffect(() => {
    let active = true;
    fetchOngoingGroupCall(conversationId)
      .then((r) => {
        if (!active) return;
        primeOngoingGroupCall(
          conversationId,
          r ? { callId: r.call_id, room: r.room, type: r.type } : null
        );
      })
      .catch(() => undefined);
    return () => {
      active = false;
    };
  }, [conversationId, primeOngoingGroupCall]);

  const call = ongoingGroupCall(conversationId);
  if (!call) return null;

  const Icon = call.type === "video" ? Video : Phone;

  return (
    <div className="flex items-center gap-2.5 border-b border-border bg-brand-subtle px-3 py-2 text-brand-hover">
      <span className="relative flex h-2 w-2 shrink-0" aria-hidden>
        <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-brand-hover/60" />
        <span className="relative inline-flex h-2 w-2 rounded-full bg-brand-hover" />
      </span>
      <span className="min-w-0 flex-1 truncate text-sm font-medium">Group call in progress</span>
      <button
        type="button"
        onClick={() => joinGroupCall(call.callId, call.room, conversationId, call.type, title)}
        className="accent-gradient inline-flex shrink-0 items-center gap-1.5 rounded-full px-3.5 py-1 text-xs font-semibold text-white shadow-accent-glow transition-transform active:scale-95"
      >
        <Icon className="h-3.5 w-3.5" aria-hidden />
        Join
      </button>
    </div>
  );
}
