"use client";

import type { ReactNode } from "react";
import { ThemeProvider as NextThemesProvider } from "next-themes";
import { MotionConfig } from "framer-motion";

// Wraps next-themes: manages the "dark"/"light" class on <html>, persists the choice to localStorage,
// and injects a blocking anti-flash script so the theme is applied before first paint. Default is LIGHT
// (the approved periwinkle mockup is a white-surface design); two explicit themes only (no system mode). disableTransitionOnChange
// avoids a jarring full-page transition when switching.
//
// MotionConfig reducedMotion="user" makes EVERY framer-motion animation honor the OS
// prefers-reduced-motion setting (transforms are dropped, opacity kept) — the app-wide motion safety net
// alongside the CSS reduced-motion block in globals.css.
export function ThemeProvider({ children }: { children: ReactNode }) {
  return (
    <NextThemesProvider
      attribute="class"
      defaultTheme="light"
      enableSystem={false}
      disableTransitionOnChange
    >
      <MotionConfig reducedMotion="user">{children}</MotionConfig>
    </NextThemesProvider>
  );
}
