import type { Metadata, Viewport } from "next";
import type { ReactNode } from "react";
import { DM_Sans, Space_Grotesk } from "next/font/google";
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

export const metadata: Metadata = {
  title: "Skifi",
  description: "Skifi — messaging that feels effortless.",
  // PWA (web-push phase 2): installable manifest + iOS home-screen metadata. iOS Safari only allows
  // web-push AFTER Add-to-Home-Screen, and reads these to install cleanly.
  manifest: "/manifest.json",
  appleWebApp: {
    capable: true,
    statusBarStyle: "default",
    title: "Skifi"
  },
  icons: {
    icon: "/icon-192.png",
    apple: "/apple-touch-icon.png"
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
      className={`${dmSans.variable} ${spaceGrotesk.variable}`}
      suppressHydrationWarning
    >
      <body className="min-h-screen bg-bg font-sans text-fg antialiased">
        <ThemeProvider>{children}</ThemeProvider>
      </body>
    </html>
  );
}
