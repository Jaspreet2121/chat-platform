import { describe, expect, it } from "vitest";
import type { DatingCard, DatingMatchEntry, DatingTagCatalog, DatingTagsResponse } from "@/lib/api";
import {
  DECK_PREFETCH_AT,
  MAX_TURN_ONS,
  computeAge,
  fetchTagCatalog,
  partitionTurnOns,
  prefsPayload,
  sharedChips,
  tagLabels,
  toggleTurnOn,
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
  distance_km: 3,
  intention: "open",
  turn_ons: [],
  shared_turn_ons: []
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
  intention: "open",
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
    expect(validateSetup(validDraft({ intention: "" }), TODAY).intention).toBeTruthy();
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

// ---- v2 (106): catalog + tags ----

const CATALOG: DatingTagCatalog = {
  intentions: [
    { key: "serious", label: "Serious relationship" },
    { key: "open", label: "Open to either" }
  ],
  turn_ons: [
    { key: "kissing", label: "Kissing", category: "romance" },
    { key: "cuddling", label: "Cuddling", category: "romance" },
    { key: "deep_talks", label: "Deep talks", category: "vibes" },
    { key: "chai_dates", label: "Chai dates", category: "vibes" }
  ]
};

function memoryStorage(initial: Record<string, string> = {}) {
  const store = new Map(Object.entries(initial));
  return {
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => void store.set(key, value),
    dump: () => store
  };
}

describe("tag catalog ETag cache", () => {
  const ok = (etag: string): DatingTagsResponse => ({ status: 200, etag, body: CATALOG });

  it("200 stores etag+body; the next request sends If-None-Match and 304 serves the copy", async () => {
    const storage = memoryStorage();
    const seen: Array<string | null> = [];

    const first = await fetchTagCatalog({
      request: async (etag) => {
        seen.push(etag);
        return ok('"abc"');
      },
      storage
    });
    expect(first).toEqual(CATALOG);
    expect(seen).toEqual([null]);

    const second = await fetchTagCatalog({
      request: async (etag) => {
        seen.push(etag);
        return { status: 304, etag: '"abc"', body: null };
      },
      storage
    });
    expect(second).toEqual(CATALOG);
    expect(seen).toEqual([null, '"abc"']);
  });

  it("a failed refresh falls back to the stored copy; with nothing stored it throws", async () => {
    const storage = memoryStorage();
    await fetchTagCatalog({ request: async () => ok('"abc"'), storage });

    const fallback = await fetchTagCatalog({
      request: async () => {
        throw new Error("offline");
      },
      storage
    });
    expect(fallback).toEqual(CATALOG);

    await expect(
      fetchTagCatalog({
        request: async () => {
          throw new Error("offline");
        },
        storage: memoryStorage()
      })
    ).rejects.toThrow();
  });
});

describe("turn-on selection", () => {
  it("keeps TAP ORDER (the wire order) and toggles off in place", () => {
    let selected: string[] = [];
    selected = toggleTurnOn(selected, "chai_dates");
    selected = toggleTurnOn(selected, "kissing");
    selected = toggleTurnOn(selected, "deep_talks");
    expect(selected).toEqual(["chai_dates", "kissing", "deep_talks"]);

    selected = toggleTurnOn(selected, "kissing");
    expect(selected).toEqual(["chai_dates", "deep_talks"]);
  });

  it("caps at 15 — adding the 16th is a no-op; removing reopens the slot", () => {
    let selected = Array.from({ length: MAX_TURN_ONS }, (_, i) => `t${i}`);
    expect(toggleTurnOn(selected, "one_more")).toBe(selected);

    selected = toggleTurnOn(selected, "t0");
    selected = toggleTurnOn(selected, "one_more");
    expect(selected).toHaveLength(MAX_TURN_ONS);
    expect(selected.at(-1)).toBe("one_more");
  });
});

describe("catalog rendering helpers", () => {
  it("partitions the two labelled groups preserving catalog order", () => {
    const { romance, vibes } = partitionTurnOns(CATALOG);
    expect(romance.map((t) => t.key)).toEqual(["kissing", "cuddling"]);
    expect(vibes.map((t) => t.key)).toEqual(["deep_talks", "chai_dates"]);
  });

  it("tagLabels spans intentions + turn-ons; null catalog is empty", () => {
    const labels = tagLabels(CATALOG);
    expect(labels.serious).toBe("Serious relationship");
    expect(labels.chai_dates).toBe("Chai dates");
    expect(tagLabels(null)).toEqual({});
  });

  it("sharedChips shows up to the max and folds the rest into +n; empty stays empty", () => {
    expect(sharedChips(["a", "b", "c", "d", "e", "f"], 4)).toEqual({
      visible: ["a", "b", "c", "d"],
      extra: 2
    });
    expect(sharedChips(["a"], 4)).toEqual({ visible: ["a"], extra: 0 });
    expect(sharedChips([], 4)).toEqual({ visible: [], extra: 0 });
  });
});

describe("prefs payload", () => {
  it("carries the intention filter and the explicit boolean (false is a value)", () => {
    expect(
      prefsPayload({
        minAge: 21,
        maxAge: 35,
        maxDistance: 50,
        intentions: ["serious", "open"],
        requireSharedTurnOn: false
      })
    ).toEqual({
      min_age: 21,
      max_age: 35,
      max_distance_km: 50,
      intentions: ["serious", "open"],
      require_shared_turn_on: false
    });

    expect(
      prefsPayload({ minAge: 18, maxAge: 100, maxDistance: 100, intentions: [], requireSharedTurnOn: true })
        .require_shared_turn_on
    ).toBe(true);
  });
});
