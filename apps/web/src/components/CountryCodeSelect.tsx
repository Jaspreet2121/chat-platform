"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { ChevronDown, Search } from "lucide-react";
import { COUNTRIES, Country, flagEmoji } from "@/lib/countries";
import { cn } from "@/lib/cn";

export type CountryCodeSelectProps = {
  value: Country;
  onChange: (country: Country) => void;
  className?: string;
  /**
   * "flush" renders the trigger border-less with a right hairline divider, so it can sit INSIDE a single
   * unified field container (the parent owns the border + focus ring). Behavior is unchanged.
   */
  variant?: "default" | "flush";
};

// A searchable country-code picker. Trigger shows the selected flag + dial code; opening reveals a
// filterable list (by country name or dial code) of every country. Click / Enter selects; Esc or a
// click outside closes.
export function CountryCodeSelect({
  value,
  onChange,
  className,
  variant = "default"
}: CountryCodeSelectProps) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const containerRef = useRef<HTMLDivElement | null>(null);
  const searchRef = useRef<HTMLInputElement | null>(null);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return COUNTRIES;
    const bare = q.replace(/^\+/, "");
    return COUNTRIES.filter(
      (country) =>
        country.name.toLowerCase().includes(q) ||
        country.dialCode.replace(/^\+/, "").includes(bare) ||
        country.iso2.toLowerCase() === q
    );
  }, [query]);

  // Close on click-outside / Esc; focus the search box when opening. Listeners attach only while open.
  useEffect(() => {
    if (!open) return;
    searchRef.current?.focus();

    function onDown(event: MouseEvent) {
      if (containerRef.current && !containerRef.current.contains(event.target as Node)) {
        setOpen(false);
      }
    }
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape") setOpen(false);
    }
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  function select(country: Country) {
    onChange(country);
    setOpen(false);
    setQuery("");
  }

  return (
    <div ref={containerRef} className={cn("relative shrink-0", className)}>
      <button
        type="button"
        onClick={() => setOpen((value) => !value)}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-label={`Country code: ${value.name} ${value.dialCode}`}
        className={cn(
          "flex h-11 items-center gap-1.5 text-sm text-fg outline-none transition-colors",
          variant === "flush"
            ? "rounded-l-xl border-r border-border bg-transparent pl-3.5 pr-2.5 hover:bg-elevated"
            : "rounded-xl border border-border bg-elevated px-3 hover:border-border-strong focus:border-brand focus:ring-2 focus:ring-brand-ring"
        )}
      >
        <span className="text-base leading-none">{flagEmoji(value.iso2)}</span>
        <span className="tabular-nums">{value.dialCode}</span>
        <ChevronDown className="h-4 w-4 text-faint" aria-hidden />
      </button>

      {open && (
        <div className="absolute left-0 top-full z-30 mt-1 w-72 max-w-[80vw] overflow-hidden rounded-xl border border-border bg-surface shadow-elevated animate-scale-in">
          <div className="border-b border-border p-2">
            <div className="relative">
              <Search
                className="pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-faint"
                aria-hidden
              />
              <input
                ref={searchRef}
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                placeholder="Search country or code"
                aria-label="Search country or code"
                className="h-9 w-full rounded-lg border border-border bg-elevated pl-8 pr-3 text-sm text-fg placeholder:text-faint outline-none focus:border-brand focus:ring-2 focus:ring-brand-ring"
              />
            </div>
          </div>

          <ul className="max-h-60 overflow-y-auto p-1" role="listbox">
            {filtered.map((country) => (
              <li key={country.iso2}>
                <button
                  type="button"
                  role="option"
                  aria-selected={country.iso2 === value.iso2}
                  onClick={() => select(country)}
                  className={cn(
                    "flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left text-sm transition-colors hover:bg-elevated",
                    country.iso2 === value.iso2 && "bg-elevated"
                  )}
                >
                  <span className="text-base leading-none">{flagEmoji(country.iso2)}</span>
                  <span className="min-w-0 flex-1 truncate text-fg">{country.name}</span>
                  <span className="shrink-0 tabular-nums text-faint">{country.dialCode}</span>
                </button>
              </li>
            ))}
            {filtered.length === 0 ? (
              <li className="px-2.5 py-3 text-center text-xs text-muted">No matches</li>
            ) : null}
          </ul>
        </div>
      )}
    </div>
  );
}
