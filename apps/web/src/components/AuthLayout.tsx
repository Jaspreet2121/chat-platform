"use client";

import type { ReactNode } from "react";
import { Check } from "lucide-react";
import { ThemeToggle } from "./ThemeToggle";

export type AuthLayoutProps = {
  /** Brand icon shown on the panel + the mobile header. */
  icon: ReactNode;
  title: string;
  /** Large headline on the brand panel. */
  tagline: string;
  /** Optional feature bullets on the brand panel. */
  highlights?: string[];
  /** Small note pinned to the bottom of the brand panel. */
  footnote?: string;
  children: ReactNode;
};

// Premium split-screen auth shell: a branded indigo glass panel (desktop) + the form area. Collapses to
// a centered card with a compact brand header on mobile. Token-driven, so the form side adapts to the
// theme; the brand panel keeps the indigo identity in both. A theme toggle sits in the corner.
export function AuthLayout({ icon, title, tagline, highlights, footnote, children }: AuthLayoutProps) {
  return (
    <main className="flex min-h-screen">
      {/* Brand panel — desktop only */}
      <aside className="relative hidden w-1/2 flex-col justify-between overflow-hidden bg-gradient-to-br from-brand to-brand-hover p-12 text-white lg:flex">
        {/* Ambient glows + dot motif for depth */}
        <div
          aria-hidden
          className="pointer-events-none absolute inset-0"
          style={{
            backgroundImage:
              "radial-gradient(600px 400px at 15% 10%, rgba(255,255,255,0.18), transparent 60%), radial-gradient(500px 500px at 100% 100%, rgba(255,255,255,0.10), transparent 55%), radial-gradient(rgba(255,255,255,0.10) 1px, transparent 1.5px)",
            backgroundSize: "auto, auto, 24px 24px"
          }}
        />

        <div className="relative flex items-center gap-3">
          <div className="flex h-11 w-11 items-center justify-center rounded-2xl bg-white/15 ring-1 ring-white/20 backdrop-blur">
            {icon}
          </div>
          <span className="text-lg font-semibold tracking-tight">{title}</span>
        </div>

        <div className="relative max-w-sm">
          <h2 className="text-3xl font-semibold leading-tight tracking-tight">{tagline}</h2>
          {highlights && highlights.length > 0 ? (
            <ul className="mt-7 space-y-3">
              {highlights.map((item) => (
                <li key={item} className="flex items-center gap-2.5 text-sm text-white/85">
                  <span className="flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-white/20">
                    <Check className="h-3 w-3" aria-hidden />
                  </span>
                  {item}
                </li>
              ))}
            </ul>
          ) : null}
        </div>

        <p className="relative text-xs text-white/60">{footnote}</p>
      </aside>

      {/* Form area */}
      <div className="relative flex w-full flex-col items-center justify-center px-4 py-10 lg:w-1/2">
        <div className="absolute right-4 top-4">
          <ThemeToggle />
        </div>

        <div className="w-full max-w-md animate-scale-in">
          {/* Compact brand mark (mobile — the panel is hidden there) */}
          <div className="mb-7 flex flex-col items-center text-center lg:hidden">
            <div className="mb-3 flex h-12 w-12 items-center justify-center rounded-2xl bg-brand text-white shadow-glow">
              {icon}
            </div>
            <span className="text-lg font-semibold tracking-tight text-fg">{title}</span>
          </div>

          {children}
        </div>
      </div>
    </main>
  );
}
