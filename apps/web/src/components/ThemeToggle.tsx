"use client";

import { useEffect, useState } from "react";
import { Moon, Sun } from "lucide-react";
import { useTheme } from "next-themes";
import { IconButton } from "./IconButton";

// Sun/Moon toggle for light/dark. The theme is only known on the client, so we defer a "mounted" flag
// (via rAF, to keep setState out of the effect body) and render the default (dark → Sun) icon until then
// — matching SSR and avoiding a hydration mismatch. Persistence + the html class are handled by
// next-themes.
export function ThemeToggle() {
  const { resolvedTheme, setTheme } = useTheme();
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    const id = requestAnimationFrame(() => setMounted(true));
    return () => cancelAnimationFrame(id);
  }, []);

  const isDark = mounted ? resolvedTheme !== "light" : true;

  return (
    <IconButton
      label={isDark ? "Switch to light theme" : "Switch to dark theme"}
      onClick={() => setTheme(isDark ? "light" : "dark")}
      type="button"
    >
      {isDark ? (
        <Sun className="h-5 w-5" aria-hidden />
      ) : (
        <Moon className="h-5 w-5" aria-hidden />
      )}
    </IconButton>
  );
}
