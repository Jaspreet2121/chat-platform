import { describe, expect, it } from "vitest";
import type { DatingCard, DatingMatchEntry } from "@/lib/api";
import {
  DECK_PREFETCH_AT,
  computeAge,
  deckNeedsPrefetch,
  deckReducer,
  fallbackLocationName,
  initialDeckState,
  initialLikesState,
  initialMatchesState,
  likesReducer,
  matchesReducer,
  reorderPhotos,
  setupServerError,
  validateSetup,
  type SetupDraft
} from "@/lib/dating";

const card = (id: string): DatingCard => ({
  user_id: id,
  display_name: `User ${id}`,
  age: 25,
  bio: null,
  photos: [],
  distance_km: 3
});

const match = (id: string): DatingMatchEntry => ({
  ...card(`peer-${id}`),
  match_id: id,
  conversation_id: `conv-${id}`,
  matched_at: "2026-08-26T10:00:00Z"
});

const validDraft = (over: Partial<SetupDraft> = {}): SetupDraft => ({
  dob: "1999-01-01",
  gender: "woman",
  interestedIn: ["man"],
  bio: "hi",
  photos: ["p1", "p2"],
  locationName: "Delhi",
  hasLocation: true,
  ...over
});

// Fixed "today" so the boundary cases are deterministic.
const TODAY = new Date(2026, 7, 26); // 2026-08-26 local

describe("computeAge / 18+ boundary", () => {
  it("counts whole years, birthday-not-yet-passed subtracts one", () => {
    expect(computeAge("2000-08-26", TODAY)).toBe(26); // birthday today → already 26
    expect(computeAge("2000-08-27", TODAY)).toBe(25); // tomorrow → not yet
    expect(computeAge("garbage", TODAY)).toBeNull();
  });

  it("EXACTLY 18 today passes; 18 tomorrow fails — the server's boundary, mirrored", () => {
    expect(validateSetup(validDraft({ dob: "2008-08-26" }), TODAY).dob).toBeUndefined();
    expect(validateSetup(validDraft({ dob: "2008-08-27" }), TODAY).dob).toMatch(/18 or older/);
  });
});

describe("validateSetup", () => {
  it("a complete draft has no errors", () => {
    expect(validateSetup(validDraft(), TODAY)).toEqual({});
  });

  it("flags each missing requirement", () => {
    expect(validateSetup(validDraft({ dob: "" }), TODAY).dob).toBeTruthy();
    expect(validateSetup(validDraft({ gender: "" }), TODAY).gender).toBeTruthy();
    expect(validateSetup(validDraft({ interestedIn: [] }), TODAY).interestedIn).toBeTruthy();
    expect(validateSetup(validDraft({ photos: ["only-one"] }), TODAY).photos).toBeTruthy();
    expect(validateSetup(validDraft({ hasLocation: false }), TODAY).location).toBeTruthy();
    expect(validateSetup(validDraft({ bio: "x".repeat(501) }), TODAY).bio).toBeTruthy();
  });

  it("maps the server error codes to copy (and passes unknown through as null)", () => {
    expect(setupServerError("dating.underage")).toMatch(/18 or older/);
    expect(setupServerError("dating.dob_locked")).toMatch(/no longer/);
    expect(setupServerError("something.else")).toBeNull();
  });
});

describe("photos", () => {
  it("reorder moves an id and keeps the rest stable — the exact PATCH payload order", () => {
    expect(reorderPhotos(["a", "b", "c", "d"], 3, 0)).toEqual(["d", "a", "b", "c"]);
    expect(reorderPhotos(["a", "b", "c"], 0, 2)).toEqual(["b", "c", "a"]);
    // Out-of-range or no-op returns the input untouched.
    expect(reorderPhotos(["a", "b"], 1, 1)).toEqual(["a", "b"]);
    expect(reorderPhotos(["a", "b"], 5, 0)).toEqual(["a", "b"]);
  });

  it("fallback location label is lat,lng at 3dp (no geocoder in this app)", () => {
    expect(fallbackLocationName(28.61394, 77.209)).toBe("28.614,77.209");
  });
});

describe("deck reducer", () => {
  it("advances on swipe and dedupes a racing prefetch", () => {
    let state = deckReducer(initialDeckState, {
      type: "loaded",
      cards: [card("a"), card("b")],
      pageSize: 25
    });
    state = deckReducer(state, { type: "swiped", userId: "a" });
    expect(state.cards.map((c) => c.user_id)).toEqual(["b"]);

    // A prefetch that still contains "b" must not duplicate it.
    state = deckReducer(state, { type: "loaded", cards: [card("b"), card("c")], pageSize: 25 });
    expect(state.cards.map((c) => c.user_id)).toEqual(["b", "c"]);
  });

  it("prefetches at the threshold and never past exhaustion", () => {
    const low = deckReducer(initialDeckState, {
      type: "loaded",
      cards: Array.from({ length: DECK_PREFETCH_AT }, (_, i) => card(`c${i}`)),
      pageSize: 25
    });
    // Short page → exhausted → no prefetch even though the stack is low.
    expect(low.exhausted).toBe(true);
    expect(deckNeedsPrefetch(low)).toBe(false);

    const fullPage = deckReducer(initialDeckState, {
      type: "loaded",
      cards: Array.from({ length: 25 }, (_, i) => card(`c${i}`)),
      pageSize: 25
    });
    expect(deckNeedsPrefetch(fullPage)).toBe(false); // 25 cards — plenty

    let drained = fullPage;
    for (let i = 0; i < 25 - DECK_PREFETCH_AT; i += 1) {
      drained = deckReducer(drained, { type: "swiped", userId: `c${i}` });
    }
    expect(drained.cards.length).toBe(DECK_PREFETCH_AT);
    expect(deckNeedsPrefetch(drained)).toBe(true); // at the threshold, not exhausted
    expect(deckNeedsPrefetch({ ...drained, loading: true })).toBe(false);
  });
});

describe("likes reducer + realtime", () => {
  it("dating_like_received bumps the badge; a (re)load clears it", () => {
    let state = likesReducer(initialLikesState, { type: "like_received" });
    state = likesReducer(state, { type: "like_received" });
    expect(state.badge).toBe(2);

    state = likesReducer(state, { type: "loaded", cards: [card("a")] });
    expect(state.badge).toBe(0);
    expect(state.loaded).toBe(true);
  });

  it("acting (like back OR pass) removes the row — a pass hides it forever", () => {
    let state = likesReducer(initialLikesState, { type: "loaded", cards: [card("a"), card("b")] });
    state = likesReducer(state, { type: "acted", userId: "a" });
    expect(state.cards.map((c) => c.user_id)).toEqual(["b"]);
  });
});

describe("matches reducer + realtime", () => {
  it("dating_matched prepends (idempotent); dating_unmatched removes by match_id", () => {
    let state = matchesReducer(initialMatchesState, { type: "loaded", matches: [match("m1")] });
    state = matchesReducer(state, { type: "matched", entry: match("m2") });
    expect(state.matches.map((m) => m.match_id)).toEqual(["m2", "m1"]);

    // The same event redelivered (both my swipe response AND the broadcast) is one row.
    state = matchesReducer(state, { type: "matched", entry: match("m2") });
    expect(state.matches.length).toBe(2);

    state = matchesReducer(state, { type: "unmatched", matchId: "m2" });
    expect(state.matches.map((m) => m.match_id)).toEqual(["m1"]);
  });
});
