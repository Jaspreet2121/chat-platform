// Per-BROWSER device identity for the Linked Devices feature.
//
// Historically every web login sent the constant device_id "web-browser", so ALL browsers on ALL
// machines collapsed into ONE device_sessions row (UNIQUE (user_id, device_id)) — the linked-devices
// list would show a single anonymous row, and revoking it signed out every browser at once. Each
// browser now mints one random id and keeps it in localStorage, so each browser is its own revocable
// device. Signed-in browsers keep their legacy "web-browser" row until they re-login — benign: it
// lists as one legacy entry and revoking it signs out exactly those legacy sessions.
//
// The display name is composed CLIENT-side (the client says what it is — no server-side user-agent
// fingerprinting), coarse on purpose: "Chrome on macOS" beats null, and beats a raw UA string.

const DEVICE_ID_KEY = "chat_device_id";

export function getOrCreateDeviceId(): string {
  if (typeof window === "undefined") return "web-browser"; // SSR render never submits a login
  try {
    const existing = window.localStorage.getItem(DEVICE_ID_KEY);
    if (existing) return existing;
    const id = `web-${crypto.randomUUID()}`;
    window.localStorage.setItem(DEVICE_ID_KEY, id);
    return id;
  } catch {
    // Storage unavailable (private mode with storage off) → a session-scoped id still beats the shared constant.
    return `web-${crypto.randomUUID()}`;
  }
}

export function deviceDisplayName(): string {
  if (typeof navigator === "undefined") return "Web Browser";
  const ua = navigator.userAgent;

  const browser = ua.includes("Edg/")
    ? "Edge"
    : ua.includes("OPR/") || ua.includes("Opera")
      ? "Opera"
      : ua.includes("Chrome/")
        ? "Chrome"
        : ua.includes("Firefox/")
          ? "Firefox"
          : ua.includes("Safari/")
            ? "Safari"
            : "Browser";

  const os = ua.includes("Windows")
    ? "Windows"
    : ua.includes("Mac OS X") || ua.includes("Macintosh")
      ? "macOS"
      : ua.includes("Android")
        ? "Android"
        : ua.includes("iPhone") || ua.includes("iPad")
          ? "iOS"
          : ua.includes("Linux")
            ? "Linux"
            : null;

  return os ? `${browser} on ${os}` : browser;
}
