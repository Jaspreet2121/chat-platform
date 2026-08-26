"use client";

import { useCallback, useEffect, useReducer, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { ArrowLeft, Flame, Heart, MessageCircle, UserRound } from "lucide-react";
import {
  deleteDatingMatch,
  fetchDatingTagsRaw,
  getCurrentSession,
  getDatingDeck,
  getDatingLikes,
  getDatingMatches,
  getDatingProfile,
  postDatingSwipe,
  type DatingCard,
  type DatingMatchEntry,
  type DatingProfile,
  type DatingSwipeResult,
  type DatingTagCatalog,
  type Session
} from "@/lib/api";
import { clearSessionTokens } from "@/lib/session";
import { createSocket, joinUserChannel, type UserChannel } from "@/lib/realtime";
import {
  deckNeedsPrefetch,
  deckReducer,
  fetchTagCatalog,
  sharedChips,
  tagLabels,
  initialDeckState,
  initialLikesState,
  initialMatchesState,
  likesReducer,
  matchesReducer
} from "@/lib/dating";
import { DatingDeck } from "@/components/dating/DatingDeck";
import { DatingLikes } from "@/components/dating/DatingLikes";
import { DatingMatches } from "@/components/dating/DatingMatches";
import { DatingSetup } from "@/components/dating/DatingSetup";
import { MatchModal } from "@/components/dating/MatchModal";
import { cn } from "@/lib/cn";

type Tab = "deck" | "likes" | "matches" | "profile";

const DECK_PAGE = 25;

type MatchToast = {
  name: string | null;
  photo: string | null;
  /** Common-ground labels for the modal's "You both like …" line. */
  sharedLabels: string[];
  conversationId: string | null;
};

/**
 * /dating — its own top-level section with a sub-nav (Deck · Likes · Matches · My profile). Gated:
 * profile absent or disabled → the setup screen. Realtime rides the user channel: dating_matched
 * adds a match live (and pops the modal when it was MY like that completed it — the swipe response
 * covers that; the event covers the OTHER side), dating_unmatched removes one, dating_like_received
 * bumps the Likes badge.
 */
export default function DatingPage() {
  const router = useRouter();
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<DatingProfile | null>(null);
  const [tab, setTab] = useState<Tab>("deck");
  const [deck, dispatchDeck] = useReducer(deckReducer, initialDeckState);
  const [likes, dispatchLikes] = useReducer(likesReducer, initialLikesState);
  const [matches, dispatchMatches] = useReducer(matchesReducer, initialMatchesState);
  const [matchToast, setMatchToast] = useState<MatchToast | null>(null);
  const [catalog, setCatalog] = useState<DatingTagCatalog | null>(null);
  const catalogRef = useRef<DatingTagCatalog | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const channelRef = useRef<UserChannel | null>(null);
  const deckLoadingRef = useRef(false);

  const enabled = profile?.enabled === true;

  // ---- data loads -------------------------------------------------------------------------------

  const loadDeck = useCallback(async () => {
    if (deckLoadingRef.current) return;
    deckLoadingRef.current = true;
    dispatchDeck({ type: "loading" });
    try {
      const cards = await getDatingDeck(DECK_PAGE);
      dispatchDeck({ type: "loaded", cards, pageSize: DECK_PAGE });
      setLoadError(null);
    } catch (error) {
      dispatchDeck({ type: "loaded", cards: [], pageSize: 0 });
      setLoadError(error instanceof Error ? error.message : "Couldn't load the deck.");
    } finally {
      deckLoadingRef.current = false;
    }
  }, []);

  const loadLikes = useCallback(async () => {
    try {
      const page = await getDatingLikes();
      dispatchLikes({ type: "loaded", cards: page.cards ?? [] });
    } catch {
      /* the empty state covers it; retry on next visit */
    }
  }, []);

  const loadMatches = useCallback(async () => {
    try {
      const page = await getDatingMatches();
      dispatchMatches({ type: "loaded", matches: page.matches ?? [] });
    } catch {
      /* same */
    }
  }, []);

  // ---- session + profile gate -------------------------------------------------------------------

  useEffect(() => {
    let cancelled = false;

    async function boot() {
      try {
        const current = await getCurrentSession();
        if (cancelled) return;
        setSession(current);

        // The tag catalog (106) — ETag-cached in localStorage; failure degrades to raw keys.
        void fetchTagCatalog({ request: fetchDatingTagsRaw, storage: window.localStorage })
          .then((tags) => {
            if (!cancelled) {
              catalogRef.current = tags;
              setCatalog(tags);
            }
          })
          .catch(() => {});
        const dating = await getDatingProfile();
        if (cancelled) return;
        setProfile(dating);
        if (dating.enabled) {
          void loadDeck();
          void loadLikes();
          void loadMatches();
        } else {
          setTab("profile");
        }
      } catch {
        clearSessionTokens();
        router.replace("/login");
      }
    }

    void boot();
    return () => {
      cancelled = true;
    };
  }, [router, loadDeck, loadLikes, loadMatches]);

  // ---- realtime ---------------------------------------------------------------------------------

  useEffect(() => {
    if (!session) return;
    let leave: (() => void) | null = null;
    const unsubscribes: Array<() => void> = [];
    let cancelled = false;

    void (async () => {
      try {
        const socket = createSocket();
        const channel = await joinUserChannel(socket, session.user_id);
        if (cancelled) {
          channel.leave();
          return;
        }
        channelRef.current = channel;
        leave = channel.leave;

        unsubscribes.push(
          channel.onDating("dating_like_received", () => {
            dispatchLikes({ type: "like_received" });
          }),
          channel.onDating("dating_matched", (payload) => {
            // The OTHER side's like completed a match with me — reflect it live.
            if (payload.match_id) {
              dispatchMatches({
                type: "matched",
                entry: {
                  match_id: payload.match_id,
                  conversation_id: payload.conversation_id ?? null,
                  matched_at: new Date().toISOString(),
                  user_id: payload.user_id ?? "",
                  display_name: null,
                  age: null,
                  bio: null,
                  photos: [],
                  distance_km: null,
                  intention: null,
                  turn_ons: [],
                  shared_turn_ons: []
                }
              });
            }
          }),
          channel.onDating("dating_unmatched", (payload) => {
            if (payload.match_id) dispatchMatches({ type: "unmatched", matchId: payload.match_id });
          })
        );
      } catch {
        // Realtime is progressive enhancement here — lists refresh on tab switches regardless.
      }
    })();

    return () => {
      cancelled = true;
      for (const unsubscribe of unsubscribes) unsubscribe();
      leave?.();
      channelRef.current = null;
    };
  }, [session]);

  // ---- actions ----------------------------------------------------------------------------------

  const openConversation = useCallback(
    (conversationId: string) => {
      router.push(`/chat?conversation=${encodeURIComponent(conversationId)}`);
    },
    [router]
  );

  const handleSwipe = useCallback(
    async (card: DatingCard, action: "like" | "pass"): Promise<DatingSwipeResult> => {
      const result = await postDatingSwipe(card.user_id, action);
      dispatchDeck({ type: "swiped", userId: card.user_id });
      dispatchLikes({ type: "acted", userId: card.user_id });

      // Prefetch when the stack runs low (event-driven — the swipe IS the trigger).
      const remaining = { ...deck, cards: deck.cards.filter((c) => c.user_id !== card.user_id) };
      if (deckNeedsPrefetch(remaining)) void loadDeck();

      if (result.matched && result.match_id) {
        dispatchMatches({
          type: "matched",
          entry: {
            ...card,
            match_id: result.match_id,
            conversation_id: result.conversation_id ?? null,
            matched_at: new Date().toISOString()
          }
        });
        setMatchToast({
          name: card.display_name,
          photo: card.photos[0] ?? null,
          sharedLabels: sharedChips(card.shared_turn_ons, 2).visible.map(
            (key) => tagLabels(catalogRef.current)[key] ?? key
          ),
          conversationId: result.conversation_id ?? null
        });
      }
      return result;
    },
    [deck, loadDeck]
  );

  const handleUnmatch = useCallback(async (match: DatingMatchEntry) => {
    await deleteDatingMatch(match.match_id);
    dispatchMatches({ type: "unmatched", matchId: match.match_id });
  }, []);

  // ---- render -----------------------------------------------------------------------------------

  if (!session || !profile) {
    return (
      <main className="flex h-dvh items-center justify-center bg-surface text-sm text-muted">
        Loading…
      </main>
    );
  }

  const labels = tagLabels(catalog);

  const tabs: Array<{ id: Tab; label: string; icon: typeof Flame; badge?: number }> = [
    { id: "deck", label: "Deck", icon: Flame },
    { id: "likes", label: "Likes", icon: Heart, badge: likes.badge },
    { id: "matches", label: "Matches", icon: MessageCircle },
    { id: "profile", label: "My profile", icon: UserRound }
  ];

  return (
    <main className="mx-auto flex h-dvh w-full max-w-2xl flex-col bg-surface">
      <header className="flex items-center gap-2 border-b border-border/60 px-3 py-2">
        <button
          type="button"
          aria-label="Back to chats"
          onClick={() => router.push("/chat")}
          className="rounded-lg p-2 text-muted hover:bg-elevated hover:text-fg"
        >
          <ArrowLeft className="h-5 w-5" aria-hidden />
        </button>
        <h1 className="text-base font-semibold text-fg">Dating</h1>
      </header>

      {/* Sub-nav */}
      <nav aria-label="Dating sections" className="flex border-b border-border/60 px-2">
        {tabs.map(({ id, label, icon: Icon, badge }) => {
          const disabled = !enabled && id !== "profile";
          return (
            <button
              key={id}
              type="button"
              disabled={disabled}
              onClick={() => {
                setTab(id);
                if (id === "likes" && enabled) void loadLikes();
                if (id === "matches" && enabled) void loadMatches();
              }}
              aria-current={tab === id ? "page" : undefined}
              className={cn(
                "relative flex flex-1 items-center justify-center gap-1.5 border-b-2 px-2 py-2.5 text-sm",
                tab === id
                  ? "border-brand font-medium text-brand-hover"
                  : "border-transparent text-muted hover:text-fg",
                disabled && "opacity-40"
              )}
            >
              <Icon className="h-4 w-4" aria-hidden />
              <span className="hidden sm:inline">{label}</span>
              {id === "likes" && (badge ?? 0) > 0 && (
                <span className="accent-gradient absolute right-1 top-1 flex h-4 min-w-4 items-center justify-center rounded-full px-1 text-[9px] font-semibold text-white">
                  {(badge as number) > 99 ? "99+" : badge}
                </span>
              )}
            </button>
          );
        })}
      </nav>

      {loadError && tab === "deck" && (
        <p className="px-4 pt-2 text-xs text-red-500" role="alert">
          {loadError}
        </p>
      )}

      <div className="min-h-0 flex-1 overflow-y-auto">
        {tab === "profile" && (
          <DatingSetup
            profile={profile}
            catalog={catalog}
            onSaved={(saved) => {
              const turnedOn = !profile.enabled && saved.enabled;
              setProfile(saved);
              if (turnedOn) {
                setTab("deck");
                void loadDeck();
                void loadLikes();
                void loadMatches();
              } else if (saved.enabled) {
                // Prefs (intention filter / require-shared) change what the deck contains — refetch.
                dispatchDeck({ type: "reset" });
                void loadDeck();
              }
            }}
          />
        )}
        {tab === "deck" && enabled && (
          <DatingDeck
            cards={deck.cards}
            tagLabels={labels}
            loading={deck.loading}
            onSwipe={handleSwipe}
            onOpenPrefs={() => setTab("profile")}
          />
        )}
        {tab === "likes" && enabled && (
          <DatingLikes
            cards={likes.cards}
            tagLabels={labels}
            loaded={likes.loaded}
            onAct={handleSwipe}
          />
        )}
        {tab === "matches" && enabled && (
          <DatingMatches
            matches={matches.matches}
            loaded={matches.loaded}
            onOpenChat={openConversation}
            onUnmatch={handleUnmatch}
          />
        )}
      </div>

      {matchToast && (
        <MatchModal
          name={matchToast.name}
          photo={matchToast.photo}
          sharedLabels={matchToast.sharedLabels}
          conversationId={matchToast.conversationId}
          onSayHi={openConversation}
          onDismiss={() => setMatchToast(null)}
        />
      )}
    </main>
  );
}
