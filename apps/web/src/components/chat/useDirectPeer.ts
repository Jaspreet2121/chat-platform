"use client";

import { useEffect, useState } from "react";
import { ConversationDetail, getConversation } from "@/lib/api";
import { useUserProfile } from "./useUserProfile";

// THE single source of truth for "who is the other person in a direct chat" — used by the open-chat
// header (page.tsx) AND the sidebar rows, so the two can never drift. A direct conversation's STORED
// title is the peer name from the CREATOR's perspective (the recipient sees their own name), so display
// names must always be derived from participants, never trusted from the title.
export function pickDirectPeer(
  participants: ConversationDetail["participants"],
  currentUserId?: string | null
): string | undefined {
  const list = participants ?? [];
  if (list.length === 0) return undefined;
  // Without a known viewer we can't tell who the peer is — don't guess (a wrong guess is exactly the
  // "shows my own name" bug). Callers fall back until the session arrives.
  if (!currentUserId) return undefined;
  const other = list.find((participant) => participant.user_id !== currentUserId);
  if (other) return other.user_id;
  // Self-chat (a conversation with yourself): the "peer" is you — show your own name, not blank.
  return list[0].user_id;
}

// Conversation-detail cache for peer derivation in the LIST (list items carry NO participant data —
// the list endpoint returns only id/type/title/preview). One detail fetch per direct conversation per
// session, deduped in-flight, seeded for free by the page when it loads the open chat. Same pattern
// (module cache + prime) as useUserProfile.
const detailCache = new Map<string, ConversationDetail>();
const inflight = new Map<string, Promise<ConversationDetail>>();

/** Seed the cache with an already-loaded detail (the page's own conversation load) — avoids a refetch. */
export function primeConversationDetail(detail: ConversationDetail): void {
  if (detail?.conversation_id) detailCache.set(detail.conversation_id, detail);
}

function loadDetail(conversationId: string): Promise<ConversationDetail> {
  const cached = detailCache.get(conversationId);
  if (cached) return Promise.resolve(cached);

  const existing = inflight.get(conversationId);
  if (existing) return existing;

  const pending = getConversation(conversationId)
    .then((detail) => {
      detailCache.set(conversationId, detail);
      inflight.delete(conversationId);
      return detail;
    })
    .catch((error) => {
      inflight.delete(conversationId);
      throw error;
    });

  inflight.set(conversationId, pending);
  return pending;
}

/**
 * The display name of a direct conversation's OTHER participant, for a sidebar row. Resolves the
 * conversation detail (cached) → picks the peer via `pickDirectPeer` → resolves their public profile
 * (cached). Returns null until known (callers fall back to the stored title / a generic label);
 * falls back to a short id handle when the peer has no display name. `enabled=false` (group rows,
 * no session yet) does nothing.
 */
export function useDirectPeerName(
  conversationId: string,
  enabled: boolean,
  currentUserId?: string
): string | null {
  const [detail, setDetail] = useState<ConversationDetail | null>(() =>
    enabled ? detailCache.get(conversationId) ?? null : null
  );

  useEffect(() => {
    if (!enabled || !conversationId || !currentUserId) return;
    let active = true;
    loadDetail(conversationId)
      .then((resolved) => {
        if (active) setDetail(resolved);
      })
      .catch(() => {
        // Best-effort: leave detail null — the row keeps its fallback label.
      });
    return () => {
      active = false;
    };
  }, [enabled, conversationId, currentUserId]);

  const peerId = enabled ? pickDirectPeer(detail?.participants, currentUserId) : undefined;
  const peerProfile = useUserProfile(peerId ?? null);

  if (!enabled || !peerId) return null;
  return peerProfile?.display_name?.trim() || `#${peerId.slice(0, 8)}`;
}
