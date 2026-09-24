const accessTokenKey = "chat_platform_access_token";
const refreshTokenKey = "chat_platform_refresh_token";
// The session's server-side id (099): a QR-linked browser's device_id is minted SERVER-side, so
// session_id is the one identity both login paths reliably know — session_revoked matches on it.
const sessionIdKey = "chat_platform_session_id";
// WHEN the stored access token dies, as epoch ms. Persisted so the socket can refresh BEFORE a
// (re)connect instead of presenting a dead token: phoenix's `params` callback is synchronous, so the
// token has to already be fresh by the time it runs. Absent for a session stored before this shipped
// — `getAccessExpiresAt` returns null and the freshness gate treats null as "refresh once to learn it".
const accessExpiresAtKey = "chat_platform_access_expires_at";

// MVP-only browser storage. Replace with a hardened session strategy before production.
export function getAccessToken() {
  if (typeof window === "undefined") {
    return null;
  }

  return window.localStorage.getItem(accessTokenKey);
}

/** The refresh token, for the 401 interceptor. Same MVP browser storage caveat as the access token. */
export function getRefreshToken() {
  if (typeof window === "undefined") {
    return null;
  }

  return window.localStorage.getItem(refreshTokenKey);
}

/** Epoch ms at which the stored access token expires, or null when unknown/unparseable. */
export function getAccessExpiresAt(): number | null {
  if (typeof window === "undefined") {
    return null;
  }

  const raw = window.localStorage.getItem(accessExpiresAtKey);
  if (raw === null) {
    return null;
  }

  const parsed = Number(raw);
  return Number.isFinite(parsed) ? parsed : null;
}

export function hasAccessToken() {
  return Boolean(getAccessToken());
}

export function setSessionTokens(tokens: {
  accessToken?: string;
  refreshToken?: string;
  /** Relative TTL, as the OTP-verify and refresh responses give it. */
  accessTokenExpiresInSeconds?: number;
  /** Absolute ISO-8601, as the QR-link approval gives it. Used when the relative form is absent. */
  accessExpiresAt?: string;
}) {
  if (typeof window === "undefined") {
    return;
  }

  if (tokens.accessToken) {
    window.localStorage.setItem(accessTokenKey, tokens.accessToken);
  }

  if (tokens.refreshToken) {
    window.localStorage.setItem(refreshTokenKey, tokens.refreshToken);
  }

  const expiresAt = resolveAccessExpiry(tokens);

  if (expiresAt !== null) {
    window.localStorage.setItem(accessExpiresAtKey, String(expiresAt));
  } else if (tokens.accessToken) {
    // A new token whose expiry we were not told: clear the OLD expiry rather than leave a stale one
    // that would read as "fresh" for a token that is nothing of the sort.
    window.localStorage.removeItem(accessExpiresAtKey);
  }
}

/** Epoch ms from whichever form the caller has, else null. Exported for its own test. */
export function resolveAccessExpiry(
  tokens: { accessTokenExpiresInSeconds?: number; accessExpiresAt?: string },
  nowMs: number = Date.now()
): number | null {
  if (typeof tokens.accessTokenExpiresInSeconds === "number" && Number.isFinite(tokens.accessTokenExpiresInSeconds)) {
    return nowMs + tokens.accessTokenExpiresInSeconds * 1000;
  }

  if (typeof tokens.accessExpiresAt === "string") {
    const parsed = Date.parse(tokens.accessExpiresAt);
    return Number.isNaN(parsed) ? null : parsed;
  }

  return null;
}

export function clearSessionTokens() {
  if (typeof window === "undefined") {
    return;
  }

  window.localStorage.removeItem(accessTokenKey);
  window.localStorage.removeItem(refreshTokenKey);
  window.localStorage.removeItem(accessExpiresAtKey);
  window.localStorage.removeItem(sessionIdKey);
}

export function setSessionId(sessionId: string | undefined | null) {
  if (typeof window === "undefined" || !sessionId) {
    return;
  }

  window.localStorage.setItem(sessionIdKey, sessionId);
}

export function getSessionId() {
  if (typeof window === "undefined") {
    return null;
  }

  return window.localStorage.getItem(sessionIdKey);
}
