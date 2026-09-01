// Dating (105) — the PURE half of the web client: setup validation (the 18+ boundary exactly as the
// server computes it), the deck/likes/matches reducers the realtime events drive, and the photo
// payload helpers. No fetch, no DOM — everything here is unit-tested in __tests__/dating.test.ts;
// the components stay thin over it.

import type { DatingCard, DatingMatchEntry, DatingTagCatalog, DatingTagsResponse } from "@/lib/api";

export const DATING_GENDERS = ["woman", "man", "nonbinary", "other"] as const;
export type DatingGender = (typeof DATING_GENDERS)[number];

export const BIO_MAX = 500;
export const MAX_TURN_ONS = 15;
/** Shared-chip row: show this many, fold the rest into "+n". */
export const SHARED_CHIPS_MAX = 4;
export const MIN_PHOTOS = 2;
export const MAX_PHOTOS = 6;
/** Prefetch the next deck page when this many (or fewer) cards remain. */
export const DECK_PREFETCH_AT = 5;

// ---- age / setup validation ---------------------------------------------------------------------

/** Age exactly as the server computes it: whole years, birthday-not-yet-passed subtracts one. */
export function computeAge(dobIso: string, today = new Date()): number | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dobIso);
  if (!match) return null;
  const [, y, m, d] = match;
  const year = Number(y);
  const month = Number(m);
  const day = Number(d);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;

  const ty = today.getFullYear();
  const tm = today.getMonth() + 1;
  const td = today.getDate();
  const birthdayPassed = tm > month || (tm === month && td >= day);
  return ty - year - (birthdayPassed ? 0 : 1);
}

export type SetupDraft = {
  dob: string;
  gender: string;
  interestedIn: string[];
  intention: string;
  bio: string;
  photos: string[];
  locationName: string;
  hasLocation: boolean;
};

export type SetupErrors = Partial<
  Record<"dob" | "gender" | "interestedIn" | "intention" | "bio" | "photos" | "location", string>
>;

/** Client-side mirror of the server's enable gate — every error the UI can catch before a request. */
export function validateSetup(draft: SetupDraft, today = new Date()): SetupErrors {
  const errors: SetupErrors = {};

  if (!draft.dob) {
    errors.dob = "Add your date of birth.";
  } else {
    const age = computeAge(draft.dob, today);
    if (age === null) errors.dob = "That date doesn't look right.";
    else if (age < 18) errors.dob = "You must be 18 or older to use Matches.";
  }

  if (!draft.gender) errors.gender = "Pick your gender.";
  if (draft.interestedIn.length === 0) errors.interestedIn = "Pick at least one.";
  if (!draft.intention) errors.intention = "Say what you're looking for.";
  if (draft.bio.length > BIO_MAX) errors.bio = `Keep your bio under ${BIO_MAX} characters.`;
  if (draft.photos.length < MIN_PHOTOS) errors.photos = `Add at least ${MIN_PHOTOS} photos.`;
  if (!draft.hasLocation) errors.location = "Set your location.";

  return errors;
}

/** The server error codes the setup form maps to friendly copy. */
export function setupServerError(code: string | undefined): string | null {
  switch (code) {
    case "dating.underage":
      return "You must be 18 or older to use Matches.";
    case "dating.dob_locked":
      return "Your date of birth can no longer be changed.";
    case "dating.photo_not_owned":
      return "One of those photos isn't from your uploads — try re-adding it.";
    case "dating.profile_incomplete":
      return "A few fields are still missing — check birthday, gender, interests, what you're looking for, photos and location.";
    case "dating.invalid_tag":
      return "One of those tags isn't in the catalog — refresh and try again.";
    default:
      return null;
  }
}

// ---- photos --------------------------------------------------------------------------------------

/** Drag-reorder: move index `from` to `to`, returning the NEW ordered media-id payload. */
export function reorderPhotos(photos: string[], from: number, to: number): string[] {
  if (from === to || from < 0 || to < 0 || from >= photos.length || to >= photos.length) {
    return photos;
  }
  const next = [...photos];
  const [moved] = next.splice(from, 1);
  next.splice(to, 0, moved);
  return next;
}

/** No geocoder exists in this app — the v1 label for a picked point is "lat,lng" (3 dp). */
export function fallbackLocationName(lat: number, lng: number): string {
  return `${lat.toFixed(3)},${lng.toFixed(3)}`;
}

// ---- tag catalog (106) ---------------------------------------------------------------------------

const TAG_CACHE_KEY = "dating.tags.v1";

type TagCacheEntry = { etag: string; catalog: DatingTagCatalog };

type TagStorage = Pick<Storage, "getItem" | "setItem">;

/**
 * The ETag cache over GET /dating/tags, pure over an injected request/storage pair (unit-tested):
 * send If-None-Match when a copy is stored; 304 → the stored copy; 200 → store etag+body; any
 * error → fall back to the stored copy if one exists, else throw.
 */
export async function fetchTagCatalog(deps: {
  request: (etag: string | null) => Promise<DatingTagsResponse>;
  storage: TagStorage;
}): Promise<DatingTagCatalog> {
  let cached: TagCacheEntry | null = null;
  try {
    const raw = deps.storage.getItem(TAG_CACHE_KEY);
    if (raw) cached = JSON.parse(raw) as TagCacheEntry;
  } catch {
    cached = null;
  }

  let response: DatingTagsResponse;
  try {
    response = await deps.request(cached?.etag ?? null);
  } catch (error) {
    if (cached) return cached.catalog;
    throw error;
  }

  if (response.status === 304 && cached) return cached.catalog;

  if (response.status === 200 && response.body) {
    if (response.etag) {
      try {
        deps.storage.setItem(TAG_CACHE_KEY, JSON.stringify({ etag: response.etag, catalog: response.body }));
      } catch {
        /* storage full/blocked — the fetch still succeeded */
      }
    }
    return response.body;
  }

  if (cached) return cached.catalog;
  throw new Error("Couldn't load the tag catalog.");
}

/** Toggle a turn-on chip. SELECTION ORDER IS THE PAYLOAD ORDER (tap order, the wire contract);
 *  adding beyond the cap is a no-op — the counter shows why. */
export function toggleTurnOn(selected: string[], key: string, max = MAX_TURN_ONS): string[] {
  if (selected.includes(key)) return selected.filter((k) => k !== key);
  if (selected.length >= max) return selected;
  return [...selected, key];
}

/** The two labelled chip groups, preserving catalog order inside each. */
export function partitionTurnOns(catalog: DatingTagCatalog): {
  romance: DatingTagCatalog["turn_ons"];
  vibes: DatingTagCatalog["turn_ons"];
} {
  return {
    romance: catalog.turn_ons.filter((tag) => tag.category === "romance"),
    vibes: catalog.turn_ons.filter((tag) => tag.category === "vibes")
  };
}

/** key → label lookup across intentions + turn-ons (unknown keys fall back to the key itself). */
export function tagLabels(catalog: DatingTagCatalog | null): Record<string, string> {
  if (!catalog) return {};
  const labels: Record<string, string> = {};
  for (const tag of catalog.intentions) labels[tag.key] = tag.label;
  for (const tag of catalog.turn_ons) labels[tag.key] = tag.label;
  return labels;
}

/** The "You both like:" row — up to `max` chips + a "+n" overflow marker (empty → no row). */
export function sharedChips(
  shared: string[],
  max = SHARED_CHIPS_MAX
): { visible: string[]; extra: number } {
  return { visible: shared.slice(0, max), extra: Math.max(0, shared.length - max) };
}

/** The prefs payload — intentions [] means "all"; the boolean rides explicitly (false is a value). */
export function prefsPayload(input: {
  minAge: number;
  maxAge: number;
  maxDistance: number;
  intentions: string[];
  requireSharedTurnOn: boolean;
}): {
  min_age: number;
  max_age: number;
  max_distance_km: number;
  intentions: string[];
  require_shared_turn_on: boolean;
} {
  return {
    min_age: input.minAge,
    max_age: input.maxAge,
    max_distance_km: input.maxDistance,
    intentions: input.intentions,
    require_shared_turn_on: input.requireSharedTurnOn
  };
}

// ---- deck reducer --------------------------------------------------------------------------------

export type DeckState = {
  cards: DatingCard[];
  /** The server returned fewer than a full page — no more to prefetch. */
  exhausted: boolean;
  loading: boolean;
};

export const initialDeckState: DeckState = { cards: [], exhausted: false, loading: false };

export type DeckAction =
  | { type: "loading" }
  | { type: "loaded"; cards: DatingCard[]; pageSize: number }
  | { type: "swiped"; userId: string }
  | { type: "reset" };

export function deckReducer(state: DeckState, action: DeckAction): DeckState {
  switch (action.type) {
    case "loading":
      return { ...state, loading: true };
    case "loaded": {
      // Append, deduped — a prefetch can race a swipe and repeat a card.
      const seen = new Set(state.cards.map((card) => card.user_id));
      const fresh = action.cards.filter((card) => !seen.has(card.user_id));
      return {
        cards: [...state.cards, ...fresh],
        exhausted: action.cards.length < action.pageSize,
        loading: false
      };
    }
    case "swiped":
      return { ...state, cards: state.cards.filter((card) => card.user_id !== action.userId) };
    case "reset":
      return { ...initialDeckState };
  }
}

/** Prefetch when the stack is running low and the server may have more. */
export function deckNeedsPrefetch(state: DeckState): boolean {
  return !state.loading && !state.exhausted && state.cards.length <= DECK_PREFETCH_AT;
}

// ---- likes reducer -------------------------------------------------------------------------------

export type LikesState = {
  cards: DatingCard[];
  /** Live count bumped by dating_like_received; cleared when the list is (re)loaded. */
  badge: number;
  loaded: boolean;
};

export const initialLikesState: LikesState = { cards: [], badge: 0, loaded: false };

export type LikesAction =
  | { type: "loaded"; cards: DatingCard[] }
  | { type: "like_received" }
  | { type: "acted"; userId: string }
  | { type: "reset" };

export function likesReducer(state: LikesState, action: LikesAction): LikesState {
  switch (action.type) {
    case "loaded":
      // A fresh list IS the truth — the badge is only for likes that arrived since we last looked.
      return { cards: action.cards, badge: 0, loaded: true };
    case "like_received":
      return { ...state, badge: state.badge + 1 };
    case "acted":
      // Like-back or pass: the row leaves my list either way (pass hides it forever server-side).
      return { ...state, cards: state.cards.filter((card) => card.user_id !== action.userId) };
    case "reset":
      return { ...initialLikesState };
  }
}

// ---- matches reducer -----------------------------------------------------------------------------

export type MatchesState = {
  matches: DatingMatchEntry[];
  loaded: boolean;
};

export const initialMatchesState: MatchesState = { matches: [], loaded: false };

export type MatchesAction =
  | { type: "loaded"; matches: DatingMatchEntry[] }
  | { type: "matched"; entry: DatingMatchEntry }
  | { type: "unmatched"; matchId: string }
  | { type: "reset" };

export function matchesReducer(state: MatchesState, action: MatchesAction): MatchesState {
  switch (action.type) {
    case "loaded":
      return { matches: action.matches, loaded: true };
    case "matched": {
      // Live add (dating_matched or a like-back in this tab): newest first, idempotent.
      if (state.matches.some((match) => match.match_id === action.entry.match_id)) return state;
      return { ...state, matches: [action.entry, ...state.matches] };
    }
    case "unmatched":
      return {
        ...state,
        matches: state.matches.filter((match) => match.match_id !== action.matchId)
      };
    case "reset":
      return { ...initialMatchesState };
  }
}
