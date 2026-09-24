/**
 * REFRESH-ON-401 (web). The piece that was missing, and the reason the shorter access-token TTL
 * ("Part 4") has been held: before this, ANY 401 while holding a token cleared the session and
 * redirected to /login. Shortening the TTL would therefore have signed everyone out on schedule.
 *
 * Three rules, and each exists because of a specific way this goes wrong:
 *
 *   1. SINGLE FLIGHT. A chat screen fires many requests at once, so an expired token produces many
 *      simultaneous 401s. Refreshing per-401 would send N concurrent /auth/refresh calls with the
 *      SAME token — and the server rotates on every refresh, so the first wins and the rest look
 *      exactly like token REUSE. The client would sign itself out by trying too hard. Every caller
 *      shares one in-flight promise.
 *
 *   2. RETRY ONCE. Not a loop. If the retried request 401s again the session is genuinely gone, and
 *      retrying further just multiplies the reuse risk above.
 *
 *   3. SIGN OUT ONLY ON A SERVER VERDICT. A network error is not an answer — offline, a captive
 *      portal, a 502 mid-deploy must leave the session alone, because the tokens may still be
 *      perfectly good. Only the four codes below mean the server has decided.
 */

/** The server has decided this session is over. Anything else is treated as transient. */
const SIGN_OUT_CODES = [
  "auth.refresh_expired",
  "auth.refresh_invalid",
  "auth.session_revoked",
  "auth.refresh_reused"
] as const;

export type SignOutCode = (typeof SIGN_OUT_CODES)[number];

export type RefreshOutcome =
  /** New tokens are stored; the caller may retry. */
  | { status: "refreshed" }
  /** The server says this session is over. Clear tokens and go to /login. */
  | { status: "signed_out"; code: SignOutCode }
  /** Transient — network, 5xx, malformed body. KEEP the session; the caller just fails this request. */
  | { status: "failed"; reason: string };

/**
 * Does this failure mean the session is over?
 *
 * PURE, and deliberately narrow: an allowlist, not a denylist. A code we have never seen (a new
 * server error, a proxy's own JSON, a typo) is transient, because the cost of being wrong is
 * asymmetric — wrongly signing out destroys work the user was in the middle of, wrongly staying
 * signed in costs one failed request that the next action retries.
 */
export function shouldSignOut(code: string | null | undefined): code is SignOutCode {
  return typeof code === "string" && (SIGN_OUT_CODES as readonly string[]).includes(code);
}

/**
 * Is the stored access token too close to expiry to be worth presenting?
 *
 * PURE. `null` — a session stored before the expiry was persisted, or a login response that did not
 * carry one — is treated as STALE: one refresh teaches us the real expiry and everything after it is
 * exact. The alternative (assume fresh) leaves the socket presenting a token it cannot reason about,
 * which is the bug this exists to close.
 *
 * The leeway is what makes this safe for a SYNCHRONOUS consumer. phoenix's `params` callback cannot
 * await, so the token must already be fresh when it runs; refreshing a minute early is what buys that.
 */
export function shouldRefreshAccessToken(
  expiresAtMs: number | null,
  nowMs: number,
  leewayMs = 60_000
): boolean {
  if (expiresAtMs === null) {
    return true;
  }

  return expiresAtMs - nowMs <= leewayMs;
}

/** What the freshness gate did. `fresh` means it decided nothing needed doing — no network at all. */
export type FreshnessResult = { status: "fresh" } | RefreshOutcome;

/**
 * Build the "make sure the access token is usable" gate the socket and the visibility handler call.
 *
 * Every dependency is injected so the decision is testable without a browser, a clock or a server.
 * It does NOT add a second single-flight: `refresh` is already the shared one, so N concurrent
 * callers through a stale gate still produce exactly ONE rotation — which is the property that keeps
 * a tab waking up from sleep from firing a refresh storm the server would read as token reuse.
 */
export function createFreshnessGate(deps: {
  readExpiry: () => number | null;
  now: () => number;
  refresh: () => Promise<RefreshOutcome>;
  leewayMs?: number;
}): () => Promise<FreshnessResult> {
  return async () => {
    if (!shouldRefreshAccessToken(deps.readExpiry(), deps.now(), deps.leewayMs)) {
      return { status: "fresh" };
    }

    return deps.refresh();
  };
}

/**
 * Wrap an async function so that concurrent callers share ONE execution.
 *
 * PURE in the sense that matters for testing: no network, no storage, no globals — it takes a
 * function and returns a function. While a call is in flight every caller gets that same promise;
 * once it settles the slot is released, so a LATER 401 (a second expiry, an hour on) starts a fresh
 * refresh rather than replaying the old result.
 *
 * The release is in a `finally` so a rejection cannot wedge the slot shut — a single network blip
 * would otherwise make every future refresh return the same rejected promise forever.
 */
export function createSingleFlight<T>(run: () => Promise<T>): () => Promise<T> {
  let inFlight: Promise<T> | null = null;

  return () => {
    if (inFlight) {
      return inFlight;
    }

    const started = (async () => run())().finally(() => {
      if (inFlight === started) {
        inFlight = null;
      }
    });

    inFlight = started;
    return started;
  };
}

/**
 * Turn a /auth/refresh response into an outcome.
 *
 * PURE. Split out from the fetch so the decision is testable without a server, and so the fetch has
 * no judgement in it at all.
 *
 * A 401 carrying one of the four codes is the only path to `signed_out`. A 401 with any OTHER code
 * is transient: it is likelier to be a gateway that was not rebuilt (which answers 400/401 with its
 * own code) than a real verdict on this session.
 */
export function classifyRefreshResponse(
  status: number,
  body: { access_token?: string; error?: { code?: string } } | null
): RefreshOutcome {
  if (status >= 200 && status < 300) {
    return body?.access_token
      ? { status: "refreshed" }
      : { status: "failed", reason: "refresh returned no access_token" };
  }

  const code = body?.error?.code;

  if (shouldSignOut(code)) {
    return { status: "signed_out", code };
  }

  return { status: "failed", reason: `refresh failed with ${status}${code ? ` (${code})` : ""}` };
}
