"use client";

import { ChevronLeft, ChevronRight } from "lucide-react";
import { Button } from "@/components";
import { cn } from "@/lib/cn";
import { PAGE_SIZES, clampPage, isPageSize, pageNumbers, pageSummary } from "@/lib/pager";
import type { Paging } from "@/app/admin/_usePaging";

// "Page N of M · total", numbered buttons with ellipses, prev/next, and the size selector. Every
// enabled/disabled decision comes from the SERVER's envelope; nothing here guesses whether another
// page exists.
export function Pager({ paging, disabled }: { paging: Paging; disabled?: boolean }) {
  const { envelope } = paging;
  if (!envelope) return null;

  const current = clampPage(envelope.page, envelope.total_pages);
  const last = Math.max(1, envelope.total_pages);

  return (
    <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
      <p className="text-xs text-faint tabular-nums">{pageSummary(envelope)}</p>

      <div className="flex flex-wrap items-center gap-2">
        <label className="flex items-center gap-1.5 text-xs text-muted">
          Rows
          <select
            className="h-8 rounded-lg border border-border bg-elevated px-2 text-xs text-fg outline-none focus:border-brand"
            value={paging.pageSize}
            disabled={disabled}
            onChange={(e) => {
              const size = Number(e.target.value);
              if (isPageSize(size)) paging.changePageSize(size);
            }}
          >
            {PAGE_SIZES.map((size) => (
              <option key={size} value={size}>
                {size}
              </option>
            ))}
          </select>
        </label>

        {last > 1 ? (
          <nav className="flex items-center gap-1" aria-label="Pages">
            <Button
              size="sm"
              variant="ghost"
              disabled={disabled || current <= 1}
              onClick={() => paging.goTo(current - 1)}
              aria-label="Previous page"
            >
              <ChevronLeft className="h-4 w-4" aria-hidden />
            </Button>

            {pageNumbers(current, last).map((item, i) =>
              item === "…" ? (
                <span key={`gap-${i}`} className="px-1 text-xs text-faint" aria-hidden>
                  …
                </span>
              ) : (
                <button
                  key={item}
                  type="button"
                  disabled={disabled}
                  onClick={() => paging.goTo(item)}
                  aria-current={item === current ? "page" : undefined}
                  className={cn(
                    "h-8 min-w-8 rounded-lg px-2 text-xs tabular-nums transition-colors",
                    item === current
                      ? "bg-brand text-white"
                      : "text-muted hover:bg-elevated hover:text-fg",
                    disabled && "cursor-not-allowed opacity-50"
                  )}
                >
                  {item}
                </button>
              )
            )}

            <Button
              size="sm"
              variant="ghost"
              disabled={disabled || current >= last}
              onClick={() => paging.goTo(current + 1)}
              aria-label="Next page"
            >
              <ChevronRight className="h-4 w-4" aria-hidden />
            </Button>
          </nav>
        ) : null}
      </div>
    </div>
  );
}
