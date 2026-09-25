import { describe, expect, it } from "vitest";
import {
  canGoNext,
  canGoPrev,
  initialPagerState,
  pagerNext,
  pagerParams,
  pagerPrev,
  pagerReceived,
  pagerRequest,
  pagerReset
} from "@/lib/cursorPager";

describe("cursorPager", () => {
  it("asks for no cursor on the first page", () => {
    expect(pagerParams(initialPagerState)).toEqual({});
  });

  it("offers a direction only when the server returned a cursor for it", () => {
    const first = pagerReceived(initialPagerState, {
      page_size: 50,
      next_cursor: "c1",
      prev_cursor: null
    });
    expect(canGoNext(first)).toBe(true);
    // No prev cursor from the server => no Back button. Offering one would load a page that is not
    // there and teach people the list cannot be trusted.
    expect(canGoPrev(first)).toBe(false);
  });

  it("walks forward and sends the cursor with a direction", () => {
    const first = pagerReceived(initialPagerState, { page_size: 50, next_cursor: "c1" });
    const second = pagerNext(first);
    expect(pagerParams(second)).toEqual({ cursor: "c1", direction: "next" });
  });

  it("walks back with direction prev", () => {
    const onPage2 = pagerReceived(pagerNext(pagerReceived(initialPagerState, { page_size: 50, next_cursor: "c1" })), {
      page_size: 50,
      next_cursor: "c2",
      prev_cursor: "b1"
    });
    expect(pagerParams(pagerPrev(onPage2))).toEqual({ cursor: "b1", direction: "prev" });
  });

  it("refuses to step past the end", () => {
    const last = pagerReceived(initialPagerState, { page_size: 50, next_cursor: null, prev_cursor: "b" });
    // A double-click on the last page must not walk the reader onto a blank screen.
    expect(pagerNext(last)).toBe(last);
    expect(pagerPrev(pagerReceived(initialPagerState, { page_size: 50 }))).toEqual(
      pagerReceived(initialPagerState, { page_size: 50 })
    );
  });

  it("treats a response with no cursors at all as a single complete page", () => {
    const only = pagerReceived(initialPagerState, { page_size: 50 });
    expect(canGoNext(only)).toBe(false);
    expect(canGoPrev(only)).toBe(false);
  });

  it("survives a missing response body without throwing", () => {
    expect(pagerReceived(initialPagerState, null)).toEqual(initialPagerState);
  });

  it("builds request params from the request fields alone", () => {
    // Only cursor + direction decide which page is asked for. A loader that also depended on the
    // RETURNED cursors would re-run every time it stored them — an infinite fetch loop.
    expect(pagerRequest(null)).toEqual({});
    expect(pagerRequest("c1")).toEqual({ cursor: "c1", direction: "next" });
    expect(pagerRequest("b1", "prev")).toEqual({ cursor: "b1", direction: "prev" });
  });

  it("resets to the first page, which is what a filter change must do", () => {
    const deep = pagerReceived(pagerNext(pagerReceived(initialPagerState, { page_size: 50, next_cursor: "c1" })), {
      page_size: 50,
      next_cursor: "c2",
      prev_cursor: "b1"
    });
    expect(pagerParams(deep)).not.toEqual({});
    // A cursor names a row in the OLD result set; carrying it into a newly filtered list starts the
    // reader somewhere arbitrary, usually an empty page, with no way to tell that is what happened.
    expect(pagerParams(pagerReset())).toEqual({});
  });
});
