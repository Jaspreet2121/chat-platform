/**
 * WHO MAY LOAD THE ADMIN CONSOLE — the web mirror of the API's gate.
 *
 * The backend admits any CONSOLE ROLE (`SharedInfra.IAM.console_access?/1`: root, admin, moderator,
 * support) with a legacy `is_admin == true` fallback. The web layout used to admit only on
 * `is_admin === true`, which `set_user_role` sets for root and admin ONLY — so moderator and support
 * passed the API gate and were bounced from the UI. Two of the four console roles could not use the
 * console they were modelled for.
 *
 * This is the one definition, shared by the layout gate and the login page, so the two cannot drift
 * from each other or from the server. Per-page capability is still gated by permission in the nav and
 * enforced server-side by `RequirePermission` — this decides only "may you see the console at all".
 */

/** The roles that can reach `/api/v1/admin` at all. Mirrors IAM's `@console_roles`, most→least privileged. */
export const CONSOLE_ROLES = ["root", "admin", "moderator", "support"] as const;

export type ConsoleSession = {
  role?: string | null;
  permissions?: string[] | null;
  is_admin?: boolean | null;
};

/**
 * PURE. True when the session may load the console.
 *
 * Three accepted signals, in the server's own order of authority:
 *   1. a known console role;
 *   2. a non-empty permission list — the server resolved SOME capability for this session, which it
 *      only does for a console role, so trusting it keeps the UI working if a new role is added
 *      server-side before this list is updated;
 *   3. the legacy `is_admin` flag, the same fallback `RequireAdmin` keeps.
 *
 * `user` (permissions `[]`, `is_admin` false) fails all three.
 */
export function hasConsoleAccess(session: ConsoleSession | null | undefined): boolean {
  if (!session) {
    return false;
  }

  const role = typeof session.role === "string" ? session.role.trim().toLowerCase() : "";

  if ((CONSOLE_ROLES as readonly string[]).includes(role)) {
    return true;
  }

  if (Array.isArray(session.permissions) && session.permissions.length > 0) {
    return true;
  }

  return session.is_admin === true;
}
