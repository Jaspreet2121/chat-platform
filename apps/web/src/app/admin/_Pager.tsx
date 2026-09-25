"use client";

import { ChevronLeft, ChevronRight } from "lucide-react";
import { Button } from "@/components";
import { canGoNext, canGoPrev, type PagerState } from "@/lib/cursorPager";

// Next/Prev for a keyset list. Both buttons are disabled purely on what the SERVER said exists —
// there is no client-side guess about whether another page is there, because a guess is how you get
// a Next button that loads an empty page.
export function Pager({
  state,
  count,
  disabled,
  onNext,
  onPrev
}: {
  state: PagerState;
  count: number;
  disabled?: boolean;
  onNext: () => void;
  onPrev: () => void;
}) {
  const hasNext = canGoNext(state);
  const hasPrev = canGoPrev(state);

  // Nothing to page through: no controls at all rather than two dead buttons.
  if (!hasNext && !hasPrev) return null;

  return (
    <div className="mt-3 flex items-center justify-between gap-3">
      <p className="text-xs text-faint">
        {count} {count === 1 ? "row" : "rows"} on this page
      </p>
      <div className="flex gap-2">
        <Button
          size="sm"
          variant="ghost"
          disabled={!hasPrev || disabled}
          onClick={onPrev}
          aria-label="Previous page"
        >
          <ChevronLeft className="h-4 w-4" aria-hidden />
          Previous
        </Button>
        <Button
          size="sm"
          variant="ghost"
          disabled={!hasNext || disabled}
          onClick={onNext}
          aria-label="Next page"
        >
          Next
          <ChevronRight className="h-4 w-4" aria-hidden />
        </Button>
      </div>
    </div>
  );
}
