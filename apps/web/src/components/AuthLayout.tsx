"use client";

import type { ReactNode } from "react";
import { motion } from "framer-motion";
import { ThemeToggle } from "./ThemeToggle";
import { DURATION, EASE, riseItem, staggerContainer } from "@/lib/motion";

export type AuthLayoutProps = {
  /** Brand icon shown on the panel + the mobile header. */
  icon: ReactNode;
  title: string;
  /** Large headline on the brand panel. */
  tagline: string;
  /** Optional feature bullets — rendered as one quiet caption line under the transcript. */
  highlights?: string[];
  /** Small note pinned to the bottom of the brand panel. */
  footnote?: string;
  children: ReactNode;
};

// A tiny scripted exchange that lands on the product's promise — the brand panel's signature. Purely
// decorative (aria-hidden); the real content is the form. "you" bubbles pop white; peer bubbles are
// translucent on the indigo field.
const TRANSCRIPT: { from: "peer" | "you"; text: string }[] = [
  { from: "peer", text: "Ready for the launch?" },
  { from: "you", text: "Everything's shipped." },
  { from: "peer", text: "This feels effortless." }
];

// Premium split-screen auth shell: a branded indigo panel (desktop) whose hero is a living chat
// transcript — the most characteristic thing in a messaging product — plus the form area. Collapses to a
// centered card with a compact brand wordmark on mobile. Token-driven so the form side adapts to the
// theme; the brand panel keeps the indigo identity in both. Entrance staggers in (transform/opacity),
// honoring reduced-motion globally via MotionConfig.
export function AuthLayout({ icon, title, tagline, highlights, footnote, children }: AuthLayoutProps) {
  return (
    <main className="flex min-h-screen">
      {/* Brand panel — desktop only */}
      <aside className="relative hidden w-1/2 flex-col overflow-hidden bg-gradient-to-br from-brand to-brand-hover p-12 text-white lg:flex">
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

        <motion.div
          variants={staggerContainer}
          initial="hidden"
          animate="show"
          className="relative flex flex-1 flex-col justify-between"
        >
          {/* Wordmark */}
          <motion.div variants={riseItem} className="flex items-center gap-3">
            <div className="flex h-11 w-11 items-center justify-center rounded-2xl bg-white/15 ring-1 ring-white/20 backdrop-blur">
              {icon}
            </div>
            <span className="font-display text-lg font-semibold tracking-tight">{title}</span>
          </motion.div>

          {/* Hero: tagline + the living transcript */}
          <motion.div variants={staggerContainer} className="max-w-sm">
            <motion.h2
              variants={riseItem}
              className="font-display text-[2.5rem] font-semibold leading-[1.08] tracking-tight"
            >
              {tagline}
            </motion.h2>

            <div className="mt-8 flex flex-col gap-2.5" aria-hidden>
              {TRANSCRIPT.map((line) => (
                <motion.div
                  key={line.text}
                  variants={riseItem}
                  className={
                    line.from === "you"
                      ? "max-w-[80%] self-end rounded-2xl rounded-br-md bg-white px-3.5 py-2 text-sm font-medium text-brand shadow-lg shadow-black/10"
                      : "max-w-[80%] self-start rounded-2xl rounded-bl-md bg-white/12 px-3.5 py-2 text-sm text-white/90 ring-1 ring-white/15 backdrop-blur-sm"
                  }
                >
                  {line.text}
                </motion.div>
              ))}
            </div>
          </motion.div>

          {/* Feature caption (quiet, one line) + footnote */}
          <motion.div variants={riseItem}>
            {highlights && highlights.length > 0 ? (
              <p className="mb-3 text-xs leading-relaxed text-white/55">
                {highlights.join("  ·  ")}
              </p>
            ) : null}
            <p className="text-xs text-white/60">{footnote}</p>
          </motion.div>
        </motion.div>
      </aside>

      {/* Form area */}
      <div className="relative flex w-full flex-col items-center justify-center px-4 py-10 lg:w-1/2">
        <div className="absolute right-4 top-4">
          <ThemeToggle />
        </div>

        <motion.div
          initial={{ opacity: 0, y: 8 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: DURATION.slow, ease: EASE.out }}
          className="w-full max-w-md"
        >
          {/* Compact brand mark (mobile — the panel is hidden there) */}
          <div className="mb-7 flex flex-col items-center text-center lg:hidden">
            <div className="mb-3 flex h-12 w-12 items-center justify-center rounded-2xl bg-brand text-white shadow-glow">
              {icon}
            </div>
            <span className="font-display text-lg font-semibold tracking-tight text-fg">{title}</span>
          </div>

          {children}
        </motion.div>
      </div>
    </main>
  );
}
