import type { Metadata } from "next";
import type { ReactNode } from "react";

export const metadata: Metadata = {
  title: "Growblic for developers — chat, calls & presence SDK",
  description:
    "Add real-time messaging, voice calls, and presence to your product with the Growblic SDK and API. Your server holds the key; your users just chat."
};

export default function DevelopersLayout({ children }: { children: ReactNode }) {
  return children;
}
