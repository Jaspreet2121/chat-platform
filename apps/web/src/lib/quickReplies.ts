// Quick-reply validation + server-error copy (100). Pure, so the rules the server enforces are
// unit-testable and the user sees a fixable message rather than a raw envelope.

import { QUICK_REPLY_BODY_MAX, QUICK_REPLY_SHORTCUT_PATTERN } from "@/lib/api";

/** The eight built-in slash commands. Reusing one is a 409 server-side, so refuse it locally too. */
export const RESERVED_SHORTCUTS = [
  "qr",
  "pay",
  "location",
  "address",
  "website",
  "email",
  "hours",
  "contact"
];

/** → an error message to show, or null when the input is acceptable. */
export function validateQuickReply(shortcut: string, body: string): string | null {
  const trimmed = shortcut.trim().toLowerCase();

  if (!trimmed) return "Give it a shortcut.";
  if (!QUICK_REPLY_SHORTCUT_PATTERN.test(trimmed)) {
    return "Use 1–25 lowercase letters, numbers or underscores — no spaces or slash.";
  }
  if (RESERVED_SHORTCUTS.includes(trimmed)) {
    return `/${trimmed} is a built-in command — pick another shortcut.`;
  }
  if (!body.trim()) return "Write the message this shortcut sends.";
  if (body.length > QUICK_REPLY_BODY_MAX) {
    return `Keep the message under ${QUICK_REPLY_BODY_MAX} characters.`;
  }

  return null;
}

/** Map the server's error codes to copy. Unknown codes fall back to the server's own message. */
export function quickReplyError(code: string | undefined, fallback: string): string {
  switch (code) {
    case "quick_reply.reserved":
      return "That shortcut is a built-in command — pick another.";
    case "quick_reply.taken":
      return "You already use that shortcut.";
    case "quick_reply.limit":
      return "You've reached the 50 quick-reply limit.";
    case "quick_reply.not_found":
      return "That quick reply no longer exists.";
    case "quick_reply.invalid_media":
      return "That attachment isn't available.";
    case "quick_reply.rate_limited":
      return "Too many changes just now — try again in a minute.";
    case "quick_reply.unavailable":
      return "Quick replies are unavailable right now.";
    default:
      return fallback;
  }
}
