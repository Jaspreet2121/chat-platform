import type { Config } from "tailwindcss";

const config: Config = {
  darkMode: "class",
  content: ["./src/app/**/*.{ts,tsx}", "./src/components/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        // --- Theme-aware design tokens (Linear/Telegram-inspired) ---
        // Values come from CSS variables (RGB channel triples) defined per theme in globals.css
        // (.dark / :root,.light). The `<alpha-value>` placeholder lets Tailwind opacity modifiers
        // (e.g. bg-brand-subtle/60, border-border/40) keep working. The SAME token names resolve to dark
        // or light values, so components never change. Brand indigo, focus ring, and success/danger stay
        // fixed across themes for a consistent identity.
        bg: "rgb(var(--color-bg) / <alpha-value>)", // app background
        surface: "rgb(var(--color-surface) / <alpha-value>)", // cards, panels
        elevated: "rgb(var(--color-elevated) / <alpha-value>)", // raised surfaces, inputs, hover
        border: "rgb(var(--color-border) / <alpha-value>)", // hairline separators
        "border-strong": "rgb(var(--color-border-strong) / <alpha-value>)", // emphasized borders
        fg: "rgb(var(--color-fg) / <alpha-value>)", // primary text
        muted: "rgb(var(--color-muted) / <alpha-value>)", // secondary text
        faint: "rgb(var(--color-faint) / <alpha-value>)", // tertiary / placeholder
        brand: {
          DEFAULT: "#7a73e0", // periwinkle — the locked accent (gradient start); same in both themes
          hover: "rgb(var(--color-brand-hover) / <alpha-value>)", // accent text/hover (lighter on dark, darker on light)
          subtle: "rgb(var(--color-brand-subtle) / <alpha-value>)", // tint surface (deep indigo on dark, pale indigo on light)
          deep: "#4e63c8", // gradient end
          ring: "rgba(122, 115, 224, 0.35)"
        },
        success: "#22c55e",
        danger: "#ef4444",

        // --- Legacy tokens (unused by the redesigned chat; kept harmless + theme-invariant) ---
        ink: "#17202a",
        paper: "#f7f9fb",
        line: "#d8dee6",
        mint: "#0f766e"
      },
      fontFamily: {
        // Body/UI — DM Sans (warm, legible). Display — Space Grotesk (distinctive; brand moment only).
        sans: ["var(--font-dm-sans)", "ui-sans-serif", "system-ui", "sans-serif"],
        display: [
          "var(--font-space-grotesk)",
          "var(--font-dm-sans)",
          "ui-sans-serif",
          "system-ui",
          "sans-serif"
        ]
      },
      transitionTimingFunction: {
        // Shared motion rhythm (mirrors src/lib/motion.ts EASE): standard = Linear-crisp, out = decelerate.
        standard: "cubic-bezier(0.2, 0, 0, 1)",
        "out-soft": "cubic-bezier(0.16, 1, 0.3, 1)"
      },
      borderRadius: {
        lg: "0.625rem",
        xl: "0.875rem",
        "2xl": "1.125rem"
      },
      boxShadow: {
        // Surface depth shadows are theme-aware (soft neutral on light, deep black on dark) via vars
        // defined per theme in globals.css — so cards/bubbles/menus read correctly in both.
        subtle: "var(--shadow-sm)",
        pop: "var(--shadow-md)",
        elevated: "var(--shadow-lg)",
        // Indigo glows stay fixed (used on own bubbles + brand accents) — read in both themes.
        glow: "0 0 0 1px rgba(122, 115, 224, 0.2), 0 8px 30px rgba(122, 115, 224, 0.12)",
        "glow-sm": "0 6px 22px -8px rgba(122, 115, 224, 0.55)",
        // Outgoing-bubble / badge / send-button glow (soft periwinkle lift under accent elements).
        "accent-glow": "0 6px 18px -6px rgba(94, 104, 212, 0.5)"
      },
      keyframes: {
        "fade-in": {
          from: { opacity: "0" },
          to: { opacity: "1" }
        },
        "slide-up": {
          from: { opacity: "0", transform: "translateY(8px)" },
          to: { opacity: "1", transform: "translateY(0)" }
        },
        "scale-in": {
          from: { opacity: "0", transform: "scale(0.97)" },
          to: { opacity: "1", transform: "scale(1)" }
        },
        "slide-in-right": {
          from: { opacity: "0", transform: "translateX(16px)" },
          to: { opacity: "1", transform: "translateX(0)" }
        },
        // Subtle equalizer pulse for voice-message waveform bars while playing (scaleY around the bar's
        // own height; transform-only so it stays GPU-cheap across many bars).
        "voice-bar": {
          "0%, 100%": { transform: "scaleY(0.75)" },
          "50%": { transform: "scaleY(1)" }
        },
        // Signature message-bubble entrance: a refined rise + settle (opacity + slight lift/scale).
        "bubble-in": {
          from: { opacity: "0", transform: "translateY(6px) scale(0.985)" },
          to: { opacity: "1", transform: "translateY(0) scale(1)" }
        }
      },
      animation: {
        "fade-in": "fade-in 0.25s ease-out",
        "slide-up": "slide-up 0.3s cubic-bezier(0.16, 1, 0.3, 1)",
        "scale-in": "scale-in 0.25s cubic-bezier(0.16, 1, 0.3, 1)",
        "slide-in-right": "slide-in-right 0.28s cubic-bezier(0.16, 1, 0.3, 1)",
        "voice-bar": "voice-bar 0.9s ease-in-out infinite",
        "bubble-in": "bubble-in 0.32s cubic-bezier(0.16, 1, 0.3, 1)"
      }
    }
  },
  plugins: []
};

export default config;
