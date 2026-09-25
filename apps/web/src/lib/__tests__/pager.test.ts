import { describe, expect, it } from "vitest";
import {
  DEFAULT_PAGE_SIZE,
  clampPage,
  loadPageSize,
  pageNumbers,
  pageSummary,
  savePageSize
} from "@/lib/pager";

describe("pageNumbers", () => {
  it("shows every page when there are few", () => {
    expect(pageNumbers(1, 1)).toEqual([1]);
    expect(pageNumbers(2, 4)).toEqual([1, 2, 3, 4]);
  });

  it("keeps the first and last pages and elides the runs in between", () => {
    expect(pageNumbers(1, 12)).toEqual([1, 2, "…", 12]);
    expect(pageNumbers(6, 12)).toEqual([1, "…", 5, 6, 7, "…", 12]);
    expect(pageNumbers(12, 12)).toEqual([1, "…", 11, 12]);
  });

  it("shows a single hidden page rather than an ellipsis standing in for one number", () => {
    // 1 [2] 3 4 ... with current=4 of 6: pages 1,3,4,5,6 wanted; 2 is a run of ONE → shown.
    expect(pageNumbers(4, 6)).toEqual([1, 2, 3, 4, 5, 6]);
    expect(pageNumbers(5, 8)).toEqual([1, "…", 4, 5, 6, 7, 8]);
  });

  it("never asks for a page outside the list", () => {
    expect(pageNumbers(40, 12)).toEqual([1, "…", 11, 12]);
    expect(pageNumbers(0, 3)).toEqual([1, 2, 3]);
    expect(pageNumbers(1, 0)).toEqual([1]);
  });
});

describe("clampPage", () => {
  it("stays inside 1..totalPages and survives junk", () => {
    expect(clampPage(3, 12)).toBe(3);
    expect(clampPage(0, 12)).toBe(1);
    expect(clampPage(99, 12)).toBe(12);
    expect(clampPage(NaN, 12)).toBe(1);
    expect(clampPage(2, 0)).toBe(1);
  });
});

describe("pageSummary", () => {
  it("reads the way an operator says it", () => {
    expect(pageSummary({ page: 3, page_size: 50, total: 587, total_pages: 12 })).toBe(
      "Page 3 of 12 · 587 rows"
    );
    expect(pageSummary({ page: 1, page_size: 50, total: 1, total_pages: 1 })).toBe("Page 1 of 1 · 1 row");
    expect(pageSummary(null)).toBe("");
  });
});

describe("remembered page size", () => {
  function fakeStorage(initial: Record<string, string> = {}) {
    const store = { ...initial };
    return {
      getItem: (k: string) => (k in store ? store[k] : null),
      setItem: (k: string, v: string) => {
        store[k] = v;
      },
      dump: () => store
    };
  }

  it("is remembered PER LIST", () => {
    const storage = fakeStorage();
    savePageSize("audit", 100, storage);
    expect(loadPageSize("audit", storage)).toBe(100);
    expect(loadPageSize("users", storage)).toBe(DEFAULT_PAGE_SIZE);
  });

  it("refuses to remember a size that is not on the selector", () => {
    // 5000 must not survive a round trip through storage into a request.
    const storage = fakeStorage();
    savePageSize("users", 5000, storage);
    expect(storage.dump()).toEqual({});
    expect(loadPageSize("users", fakeStorage({ "admin.pageSize.users": "5000" }))).toBe(
      DEFAULT_PAGE_SIZE
    );
    expect(loadPageSize("users", fakeStorage({ "admin.pageSize.users": "junk" }))).toBe(
      DEFAULT_PAGE_SIZE
    );
  });

  it("is the default when there is no storage at all", () => {
    expect(loadPageSize("users", null)).toBe(DEFAULT_PAGE_SIZE);
  });
});
