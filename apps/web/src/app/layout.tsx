import type { Metadata, Viewport } from "next";
import type { ReactNode } from "react";
import {
  Baloo_2,
  DM_Sans,
  Kalam,
  Martel,
  Rozha_One,
  Space_Grotesk,
  Tiro_Devanagari_Hindi
} from "next/font/google";
import { ThemeProvider } from "@/components/ThemeProvider";
import "./globals.css";

// Body/UI face — DM Sans: warm, round, highly legible geometric sans (personal-messaging warmth).
const dmSans = DM_Sans({
  subsets: ["latin"],
  variable: "--font-dm-sans",
  display: "swap",
  weight: ["400", "500", "600", "700"]
});

// Display face — Space Grotesk: distinctive geometric grotesque, used with restraint for the brand
// moment (wordmark + login headline). Self-hosted via next/font, so no CDN flash.
const spaceGrotesk = Space_Grotesk({
  subsets: ["latin"],
  variable: "--font-space-grotesk",
  display: "swap",
  weight: ["400", "500", "600", "700"]
});

// ---- MESSAGE FACES (metadata.font) -----------------------------------------------------------
//
// The five faces a sender can pick per message. EVERY ONE carries a Devanagari subset alongside
// Latin: this app's users write Hindi and English in the same thread, often in the same message, and
// a face that covers only Latin would silently fall back mid-sentence — the Hindi half rendering in
// the default face while the English half honoured the choice. That is worse than not offering the
// font at all, so "Latin + Devanagari in ONE family" was the selection rule.
//
// Loaded once here (self-hosted by next/font — no CDN request, no layout flash) and exposed as CSS
// variables; RichText only ever sets a class. Weights are kept minimal: a message face needs a
// regular and a bold, and each extra weight is another file every visitor downloads.
const msgSerif = Tiro_Devanagari_Hindi({
  subsets: ["latin", "devanagari"],
  variable: "--font-msg-serif",
  display: "swap",
  weight: ["400"]
});

const msgRounded = Baloo_2({
  subsets: ["latin", "devanagari"],
  variable: "--font-msg-rounded",
  display: "swap",
  weight: ["400", "600"]
});

const msgHandwritten = Kalam({
  subsets: ["latin", "devanagari"],
  variable: "--font-msg-handwritten",
  display: "swap",
  weight: ["400", "700"]
});

const msgDisplay = Rozha_One({
  subsets: ["latin", "devanagari"],
  variable: "--font-msg-display",
  display: "swap",
  weight: ["400"]
});

const msgElegant = Martel({
  subsets: ["latin", "devanagari"],
  variable: "--font-msg-elegant",
  display: "swap",
  weight: ["400", "700"]
});

export const metadata: Metadata = {
  title: "Growblic: Chat, Call, Meet",
  description: "Growblic — chat, call and meet the people who matter.",
  // PWA (web-push phase 2): installable manifest + iOS home-screen metadata. iOS Safari only allows
  // web-push AFTER Add-to-Home-Screen, and reads these to install cleanly.
  manifest: "/manifest.json",
  appleWebApp: {
    capable: true,
    statusBarStyle: "default",
    title: "Growblic"
  },
  // The brand mark (vc40) — a white skull on an opaque black field, the same asset Android ships.
  // Declared explicitly rather than through Next's app/icon.* file convention so every path here is a
  // real file in public/ that a build check can fetch; a 404'd icon is otherwise silent.
  //
  // OPAQUE at every size on purpose: iOS ignores alpha on the touch icon and fills it black anyway,
  // and the mark's own field IS black, so there is nothing to lose and no fringing to risk.
  //
  // Dark-mode tabs are fine without a light variant: what could vanish on dark chrome is a DARK mark on
  // transparency, and this is the reverse — the white skull sits on its own opaque field, so it stays
  // legible on light and dark alike (checked at 32px, where the mark is still clearly readable).
  icons: {
    icon: [
      { url: "/favicon.ico", sizes: "16x16 32x32 48x48" },
      { url: "/icon-32.png", type: "image/png", sizes: "32x32" },
      { url: "/icon-192.png", type: "image/png", sizes: "192x192" },
      { url: "/icon-512.png", type: "image/png", sizes: "512x512" }
    ],
    apple: { url: "/apple-touch-icon.png", sizes: "180x180" }
  }
};

// viewport-fit=cover is REQUIRED for env(safe-area-inset-*) to be non-zero on notched phones — the
// safe-area padding on the app shell, tab bar and composer all depend on it. Zoom stays enabled (no
// maximumScale) for accessibility; inputs avoid iOS auto-zoom via the ≥16px rule in globals.css.
export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
  themeColor: "#7a73e0"
};

export default function RootLayout({
  children
}: Readonly<{
  children: ReactNode;
}>) {
  return (
    // suppressHydrationWarning: next-themes sets the theme class on <html> before paint, so the class
    // legitimately differs between the server-rendered and client markup.
    <html
      lang="en"
      className={`${dmSans.variable} ${spaceGrotesk.variable} ${msgSerif.variable} ${msgRounded.variable} ${msgHandwritten.variable} ${msgDisplay.variable} ${msgElegant.variable}`}
      suppressHydrationWarning
    >
      <body className="min-h-screen bg-bg font-sans text-fg antialiased">
        <ThemeProvider>{children}</ThemeProvider>
      </body>
    </html>
  );
}
