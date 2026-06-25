"use client";

import type { ReactNode } from "react";
import { ThemeProvider as NextThemesProvider } from "next-themes";

// Wraps next-themes: manages the "dark"/"light" class on <html>, persists the choice to localStorage,
// and injects a blocking anti-flash script so the theme is applied before first paint. Default is dark
// (matches the original look); two explicit themes only (no system mode). disableTransitionOnChange
// avoids a jarring full-page transition when switching.
export function ThemeProvider({ children }: { children: ReactNode }) {
  return (
    <NextThemesProvider
      attribute="class"
      defaultTheme="dark"
      enableSystem={false}
      disableTransitionOnChange
    >
      {children}
    </NextThemesProvider>
  );
}
