const accessTokenKey = "chat_platform_access_token";
const refreshTokenKey = "chat_platform_refresh_token";
// The session's server-side id (099): a QR-linked browser's device_id is minted SERVER-side, so
// session_id is the one identity both login paths reliably know — session_revoked matches on it.
const sessionIdKey = "chat_platform_session_id";

// MVP-only browser storage. Replace with a hardened session strategy before production.
export function getAccessToken() {
  if (typeof window === "undefined") {
    return null;
  }

  return window.localStorage.getItem(accessTokenKey);
}

export function hasAccessToken() {
  return Boolean(getAccessToken());
}

export function setSessionTokens(tokens: {
  accessToken?: string;
  refreshToken?: string;
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
}

export function clearSessionTokens() {
  if (typeof window === "undefined") {
    return;
  }

  window.localStorage.removeItem(accessTokenKey);
  window.localStorage.removeItem(refreshTokenKey);
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
