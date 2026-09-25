// The console's keyset pager, as pure logic so it can be tested without a DOM.
//
// A cursor pager has exactly one hard part: knowing which way you can still go. The server answers
// that by returning a null cursor for a direction that has no page, and everything here exists to
// make sure the UI never offers a button the server did not back. A Next button that loads an empty
// page teaches people not to trust the list.

import type { CursorPage, CursorParams } from "@/lib/api";

export type PagerState = {
  // Where the CURRENT page starts. null means the first page.
  cursor: string | null;
  direction: "next" | "prev";
  // The cursors the server returned for the page now on screen.
  next: string | null;
  prev: string | null;
};

export const initialPagerState: PagerState = {
  cursor: null,
  direction: "next",
  next: null,
  prev: null
};

// The request params for a page. Takes the two REQUEST fields rather than the whole state on
// purpose: a loader that depended on the returned cursors too would re-run every time it stored
// them, which is an infinite fetch loop in a React effect. Only `cursor` and `direction` decide
// which page is being asked for.
export function pagerRequest(
  cursor: string | null,
  direction: "next" | "prev" = "next"
): CursorParams {
  if (!cursor) return {};
  return { cursor, direction };
}

// The same thing given a whole state, for call sites that have one to hand.
export function pagerParams(state: PagerState): CursorParams {
  return pagerRequest(state.cursor, state.direction);
}

// Fold a server response into the state. Called after every load, including the first.
export function pagerReceived(state: PagerState, page: CursorPage | null | undefined): PagerState {
  return {
    ...state,
    next: page?.next_cursor ?? null,
    prev: page?.prev_cursor ?? null
  };
}

export function canGoNext(state: PagerState): boolean {
  return Boolean(state.next);
}

export function canGoPrev(state: PagerState): boolean {
  return Boolean(state.prev);
}

// Step forward. A no-op when the server said there is nothing ahead, so a double-click on the last
// page cannot walk the reader off the end of the list into a blank screen.
export function pagerNext(state: PagerState): PagerState {
  if (!state.next) return state;
  return { ...state, cursor: state.next, direction: "next" };
}

export function pagerPrev(state: PagerState): PagerState {
  if (!state.prev) return state;
  return { ...state, cursor: state.prev, direction: "prev" };
}

// Back to page one. THIS IS WHAT A FILTER CHANGE MUST DO: a cursor names a row in the OLD result
// set, and carrying it into a newly filtered list would start the reader somewhere arbitrary —
// usually an empty page — with no way to tell that is what happened.
export function pagerReset(): PagerState {
  return initialPagerState;
}
