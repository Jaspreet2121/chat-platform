// The reason an operator gives for looking at match history, and how long it lasts.
//
// THE SERVER REQUIRES A REASON ON EVERY CALL. This is not a client-side policy that could be skipped
// by talking to the API directly — /admin/matches answers 400 admin.reason_required without one.
// What lives here is only the "once per session-hour" part: asking on every page turn would train
// people to type "abuse" without reading the prompt, which is worse than asking less often and
// having the answer mean something.
//
// It is held in sessionStorage, deliberately, not localStorage: the reason belongs to this sitting
// at this desk. Closing the tab ends it.

export const REASON_MIN_LENGTH = 8;
export const REASON_MAX_LENGTH = 200;
// One hour, matching the "once per session-hour" rule.
export const REASON_TTL_MS = 60 * 60 * 1000;

const STORAGE_KEY = "admin.matches.reason";

export type StoredReason = { reason: string; at: number };

// Same floor the server enforces: "x" is not a reason. Trimmed, because a box of spaces is empty.
export function reasonIsValid(reason: string | null | undefined): boolean {
  if (typeof reason !== "string") return false;
  const trimmed = reason.trim();
  return trimmed.length >= REASON_MIN_LENGTH && trimmed.length <= REASON_MAX_LENGTH;
}

// Is a stored reason still usable? Anything malformed, expired, or stamped in the FUTURE is not —
// a future timestamp would otherwise outlive its hour indefinitely on a machine with a skewed clock.
export function reasonIsFresh(stored: StoredReason | null, now: number = Date.now()): boolean {
  if (!stored || !reasonIsValid(stored.reason)) return false;
  if (!Number.isFinite(stored.at)) return false;
  const age = now - stored.at;
  return age >= 0 && age < REASON_TTL_MS;
}

export function parseStoredReason(raw: string | null): StoredReason | null {
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as StoredReason;
    if (typeof parsed?.reason !== "string" || typeof parsed?.at !== "number") return null;
    return parsed;
  } catch {
    return null;
  }
}

// Storage access is wrapped: a private window, blocked site data or a full quota must cost the
// operator an extra prompt, never a broken page.
export function loadReason(now: number = Date.now()): string | null {
  if (typeof window === "undefined") return null;
  try {
    const stored = parseStoredReason(window.sessionStorage.getItem(STORAGE_KEY));
    return reasonIsFresh(stored, now) ? (stored as StoredReason).reason : null;
  } catch {
    return null;
  }
}

export function saveReason(reason: string, now: number = Date.now()): void {
  if (typeof window === "undefined" || !reasonIsValid(reason)) return;
  try {
    window.sessionStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ reason: reason.trim(), at: now } satisfies StoredReason)
    );
  } catch {
    // Nothing to do: the operator is asked again next time, which is the safe direction.
  }
}

export function clearReason(): void {
  if (typeof window === "undefined") return;
  try {
    window.sessionStorage.removeItem(STORAGE_KEY);
  } catch {
    // Same: worst case the reason stays until the tab closes.
  }
}
