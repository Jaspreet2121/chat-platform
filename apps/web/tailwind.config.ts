import type { Config } from "tailwindcss";

const config: Config = {
  darkMode: "class",
  content: ["./src/app/**/*.{ts,tsx}", "./src/components/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        // --- Dark-mode-first design tokens (Linear/Telegram-inspired) ---
        bg: "#0a0c10", // app background (deepest)
        surface: "#12151c", // cards, panels
        elevated: "#191d26", // raised surfaces, inputs, hover
        border: "#262b36", // hairline separators
        "border-strong": "#333a47", // emphasized borders
        fg: "#e7e9ee", // primary text
        muted: "#9aa3b2", // secondary text
        faint: "#5b6472", // tertiary / placeholder
        brand: {
          DEFAULT: "#6366f1", // indigo
          hover: "#818cf8",
          subtle: "#1e1b4b",
          ring: "rgba(99, 102, 241, 0.35)"
        },
        success: "#22c55e",
        danger: "#ef4444",

        // --- Legacy tokens (kept so the not-yet-redesigned chat page still renders; Slice 2) ---
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
        glow: "0 0 0 1px rgba(99, 102, 241, 0.2), 0 8px 30px rgba(99, 102, 241, 0.12)"
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
        }
      },
      animation: {
        "fade-in": "fade-in 0.25s ease-out",
        "slide-up": "slide-up 0.3s cubic-bezier(0.16, 1, 0.3, 1)",
        "scale-in": "scale-in 0.25s cubic-bezier(0.16, 1, 0.3, 1)"
      }
    }
  },
  plugins: []
};

export default config;
