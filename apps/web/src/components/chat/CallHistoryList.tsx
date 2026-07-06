"use client";

import { useEffect, useState } from "react";
import { ArrowDownLeft, ArrowUpRight, Phone, Video } from "lucide-react";
import { Avatar } from "@/components";
import { cn } from "@/lib/cn";
import { fetchCallHistory, type CallRecord } from "@/lib/api";
import { useUserProfile } from "./useUserProfile";

export type CallHistoryListProps = {
  /** Viewer's id — decides outgoing (caller===me) vs incoming for each row. */
  currentUserId?: string;
};

// Compact time for the row's right edge (mirrors the conversation list: today → clock, else short date).
function callTime(iso?: string | null): string | null {
  if (!iso) return null;
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return null;
  const now = new Date();
  const sameDay =
    date.getFullYear() === now.getFullYear() &&
    date.getMonth() === now.getMonth() &&
    date.getDate() === now.getDate();
  return sameDay
    ? date.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" })
    : date.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

function CallHistoryRow({ call, currentUserId }: { call: CallRecord; currentUserId?: string }) {
  // Avatar via the SAME cached/deduped resolver every chat row uses (names come enriched server-side).
  const profile = useUserProfile(call.counterpart_id);
  const name = call.counterpart_name?.trim() || profile?.display_name?.trim() || `${call.counterpart_id.slice(0, 8)}…`;
  const outgoing = call.caller_id === currentUserId;
  const missed = call.status === "missed";
  const TypeIcon = call.type === "video" ? Video : Phone;
  const DirectionIcon = outgoing ? ArrowUpRight : ArrowDownLeft;
  const label = missed
    ? `Missed ${call.type === "video" ? "video" : "voice"} call`
    : `${outgoing ? "Outgoing" : "Incoming"} ${call.type === "video" ? "video" : "voice"}`;
  const time = callTime(call.created_at);

  return (
    <div className="relative flex w-full items-center gap-3 px-4 py-3 text-left">
      <Avatar id={call.counterpart_id} name={name} imageUrl={profile?.avatar_url} />
      <div className="min-w-0 flex-1">
        <div className="flex items-baseline justify-between gap-2">
          <p className={cn("truncate text-sm font-medium", missed ? "text-red-500" : "text-fg")}>{name}</p>
          {time ? <span className="shrink-0 text-[11px] tabular-nums text-faint">{time}</span> : null}
        </div>
        <div className={cn("mt-0.5 flex items-center gap-1.5 text-xs", missed ? "text-red-500" : "text-muted")}>
          <DirectionIcon className="h-3.5 w-3.5 shrink-0" aria-hidden />
          <TypeIcon className="h-3.5 w-3.5 shrink-0" aria-hidden />
          <span className="truncate">{label}</span>
        </div>
      </div>
    </div>
  );
}

/**
 * Calls tab: the current user's call history (both sides), newest first — read-only (no signaling here).
 * Fetches once on mount; handles loading / empty / error. Rows reuse the conversation-row layout.
 */
export function CallHistoryList({ currentUserId }: CallHistoryListProps) {
  const [calls, setCalls] = useState<CallRecord[] | null>(null);
  const [error, setError] = useState(false);

  useEffect(() => {
    let active = true;
    fetchCallHistory()
      .then((rows) => active && setCalls(rows))
      .catch(() => active && setError(true));
    return () => {
      active = false;
    };
  }, []);

  const centered = "flex h-full flex-col items-center justify-center gap-3 bg-bg px-8 pb-[calc(84px+env(safe-area-inset-bottom))] text-center";

  if (error) {
    return (
      <div className={centered}>
        <p className="text-sm text-muted">Couldn&apos;t load your calls. Pull up later.</p>
      </div>
    );
  }

  if (calls === null) {
    return (
      <div className={centered}>
        <p className="text-sm text-muted">Loading calls…</p>
      </div>
    );
  }

  if (calls.length === 0) {
    return (
      <div className={centered}>
        <div className="accent-gradient flex h-16 w-16 items-center justify-center rounded-3xl shadow-accent-glow">
          <Phone className="h-7 w-7 text-white" aria-hidden />
        </div>
        <h1 className="text-lg font-semibold tracking-[-0.02em] text-fg">No calls yet</h1>
        <p className="max-w-[17rem] text-sm text-muted">Your voice and video calls will show up here.</p>
      </div>
    );
  }

  return (
    <div className="h-full overflow-y-auto bg-bg pb-[calc(84px+env(safe-area-inset-bottom))]">
      <div className="divide-y divide-border/60">
        {calls.map((call) => (
          <CallHistoryRow key={call.id} call={call} currentUserId={currentUserId} />
        ))}
      </div>
    </div>
  );
}
