// Dating (105) — the PURE half of the web client: setup validation (the 18+ boundary exactly as the
// server computes it), the deck/likes/matches reducers the realtime events drive, and the photo
// payload helpers. No fetch, no DOM — everything here is unit-tested in __tests__/dating.test.ts;
// the components stay thin over it.

import type { DatingCard, DatingMatchEntry } from "@/lib/api";

export const DATING_GENDERS = ["woman", "man", "nonbinary", "other"] as const;
export type DatingGender = (typeof DATING_GENDERS)[number];

export const BIO_MAX = 500;
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
  bio: string;
  photos: string[];
  locationName: string;
  hasLocation: boolean;
};

export type SetupErrors = Partial<
  Record<"dob" | "gender" | "interestedIn" | "bio" | "photos" | "location", string>
>;

/** Client-side mirror of the server's enable gate — every error the UI can catch before a request. */
export function validateSetup(draft: SetupDraft, today = new Date()): SetupErrors {
  const errors: SetupErrors = {};

  if (!draft.dob) {
    errors.dob = "Add your date of birth.";
  } else {
    const age = computeAge(draft.dob, today);
    if (age === null) errors.dob = "That date doesn't look right.";
    else if (age < 18) errors.dob = "You must be 18 or older to use Dating.";
  }

  if (!draft.gender) errors.gender = "Pick your gender.";
  if (draft.interestedIn.length === 0) errors.interestedIn = "Pick at least one.";
  if (draft.bio.length > BIO_MAX) errors.bio = `Keep your bio under ${BIO_MAX} characters.`;
  if (draft.photos.length < MIN_PHOTOS) errors.photos = `Add at least ${MIN_PHOTOS} photos.`;
  if (!draft.hasLocation) errors.location = "Set your location.";

  return errors;
}

/** The server error codes the setup form maps to friendly copy. */
export function setupServerError(code: string | undefined): string | null {
  switch (code) {
    case "dating.underage":
      return "You must be 18 or older to use Dating.";
    case "dating.dob_locked":
      return "Your date of birth can no longer be changed.";
    case "dating.photo_not_owned":
      return "One of those photos isn't from your uploads — try re-adding it.";
    case "dating.profile_incomplete":
      return "A few fields are still missing — check birthday, gender, interests, photos and location.";
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
