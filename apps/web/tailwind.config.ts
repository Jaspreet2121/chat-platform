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
          DEFAULT: "#6366f1", // indigo — same in both themes (brand identity)
          hover: "rgb(var(--color-brand-hover) / <alpha-value>)", // accent text/hover (lighter on dark, darker on light)
          subtle: "rgb(var(--color-brand-subtle) / <alpha-value>)", // tint surface (deep indigo on dark, pale indigo on light)
          ring: "rgba(99, 102, 241, 0.35)"
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
        sans: ["var(--font-inter)", "ui-sans-serif", "system-ui", "sans-serif"]
      },
      borderRadius: {
        lg: "0.625rem",
        xl: "0.875rem",
        "2xl": "1.125rem"
      },
      boxShadow: {
        subtle: "0 1px 2px rgba(0, 0, 0, 0.25)",
        elevated: "0 8px 30px rgba(0, 0, 0, 0.45)",
        glow: "0 0 0 1px rgba(99, 102, 241, 0.2), 0 8px 30px rgba(99, 102, 241, 0.12)",
        // Soft directional glow under own-message bubbles (the signature lift). Indigo, both themes.
        "glow-sm": "0 6px 22px -8px rgba(99, 102, 241, 0.55)"
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
