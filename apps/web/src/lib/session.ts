const accessTokenKey = "chat_platform_access_token";
const refreshTokenKey = "chat_platform_refresh_token";

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
}
