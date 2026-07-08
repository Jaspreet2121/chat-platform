"use client";

import { useRouter } from "next/navigation";

// Same URL shape used elsewhere (ConversationDetailsPanel). Capturing group so String.split keeps the URLs
// as separate chunks. XSS-safe: only http/https matches become anchors — everything else stays plain text.
const URL_SPLIT_RE = /(https?:\/\/[^\s<>"')\]]+)/gi;

function isHttpUrl(value: string): boolean {
  return /^https?:\/\//i.test(value);
}

// If `url` is an INTERNAL call link (this app's host + /call/<id>), return the relative "/call/<id>" path so
// it navigates in-app (no new tab). Else null. Host check uses the hostname (not a full-origin string) and
// is guarded for SSR — matches the current host, or any *.growblic.com, so shared links resolve either way.
function internalCallPath(url: string): string | null {
  try {
    const u = new URL(url);
    if (u.protocol !== "http:" && u.protocol !== "https:") return null;
    const match = u.pathname.match(/^\/call\/([^/?#]+)\/?$/);
    if (!match) return null;
    const sameHost =
      (typeof window !== "undefined" && u.hostname === window.location.hostname) ||
      u.hostname === "growblic.com" ||
      u.hostname.endsWith(".growblic.com");
    return sameHost ? `/call/${match[1]}` : null;
  } catch {
    return null;
  }
}

/**
 * Renders message text with clickable links. Non-URL chunks stay plain text (the parent's whitespace class
 * preserves wrapping/newlines). An internal call link (…/call/<id>) navigates in-app via the router; any
 * other http/https URL opens in a new tab (rel=noopener). Anchor clicks stopPropagation so they don't also
 * toggle the bubble's ⋯ menu.
 */
export function LinkifiedText({ text }: { text: string }) {
  const router = useRouter();
  const linkClass = "underline decoration-1 underline-offset-2 text-inherit";

  return (
    <>
      {text.split(URL_SPLIT_RE).map((part, i) => {
        if (!isHttpUrl(part)) {
          // Empty chunks (e.g. text starting with a URL) render nothing.
          return part ? <span key={i}>{part}</span> : null;
        }

        const internal = internalCallPath(part);
        if (internal) {
          return (
            <a
              key={i}
              href={internal}
              onClick={(e) => {
                e.stopPropagation();
                e.preventDefault();
                router.push(internal);
              }}
              className={linkClass}
            >
              {part}
            </a>
          );
        }

        return (
          <a
            key={i}
            href={part}
            target="_blank"
            rel="noopener noreferrer"
            onClick={(e) => e.stopPropagation()}
            className={linkClass}
          >
            {part}
          </a>
        );
      })}
    </>
  );
}
