// Numbered paging for the admin lists, as pure logic so it can be tested without a DOM.
//
// The server sends an envelope — page, page_size, total, total_pages — and everything here derives
// from it. Nothing on the client guesses whether another page exists: "Page N of M" and the button
// row are computed from what the server said, or not shown at all.

import type { PageEnvelope } from "@/lib/api";

export const PAGE_SIZES = [10, 20, 50, 100] as const;
export type PageSize = (typeof PAGE_SIZES)[number];
export const DEFAULT_PAGE_SIZE: PageSize = 50;

export type PageItem = number | "…";

// Which page numbers to show for `current` of `totalPages`: always the first and the last, the
// current one and its neighbours, and an ellipsis wherever a run is skipped. A run of exactly one
// hidden page is shown rather than replaced by "…", because an ellipsis standing in for a single
// number is longer than the number.
export function pageNumbers(current: number, totalPages: number): PageItem[] {
  const total = Math.max(1, Math.floor(totalPages) || 1);
  const page = clampPage(current, total);

  const wanted = new Set<number>([1, total, page - 1, page, page + 1]);
  const sorted = [...wanted].filter((n) => n >= 1 && n <= total).sort((a, b) => a - b);

  const out: PageItem[] = [];
  let previous = 0;
  for (const n of sorted) {
    if (previous !== 0 && n - previous === 2) out.push(previous + 1);
    else if (previous !== 0 && n - previous > 2) out.push("…");
    out.push(n);
    previous = n;
  }
  return out;
}

// A page the server can answer: never below 1, never past the last page.
export function clampPage(page: number, totalPages: number): number {
  const total = Math.max(1, Math.floor(totalPages) || 1);
  if (!Number.isFinite(page) || page < 1) return 1;
  return Math.min(Math.floor(page), total);
}

// "Page 3 of 12 · 587 rows" — what the operator reads to know where they are.
export function pageSummary(envelope: PageEnvelope | null | undefined): string {
  if (!envelope) return "";
  const rows = envelope.total === 1 ? "1 row" : `${envelope.total.toLocaleString()} rows`;
  return `Page ${envelope.page} of ${envelope.total_pages} · ${rows}`;
}

// --- The remembered page size, per list ----------------------------------------------------------
// localStorage, because this is a per-viewer convenience: the size somebody likes for the audit log
// on their own screen. It is validated on the way back in — storage can hold whatever an older
// build, or a person with devtools, put there — and anything unrecognised is the default.

const STORAGE_PREFIX = "admin.pageSize.";

type StorageLike = Pick<Storage, "getItem" | "setItem">;

function defaultStorage(): StorageLike | null {
  if (typeof window === "undefined") return null;
  try {
    return window.localStorage;
  } catch {
    return null;
  }
}

export function isPageSize(value: unknown): value is PageSize {
  return typeof value === "number" && (PAGE_SIZES as readonly number[]).includes(value);
}

export function loadPageSize(listKey: string, storage: StorageLike | null = defaultStorage()): PageSize {
  if (!storage) return DEFAULT_PAGE_SIZE;
  try {
    const parsed = Number(storage.getItem(STORAGE_PREFIX + listKey));
    return isPageSize(parsed) ? parsed : DEFAULT_PAGE_SIZE;
  } catch {
    return DEFAULT_PAGE_SIZE;
  }
}

export function savePageSize(
  listKey: string,
  size: number,
  storage: StorageLike | null = defaultStorage()
): void {
  if (!storage || !isPageSize(size)) return;
  try {
    storage.setItem(STORAGE_PREFIX + listKey, String(size));
  } catch {
    // A full or blocked store costs the operator a re-pick next visit, never a broken page.
  }
}
