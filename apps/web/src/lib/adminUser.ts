import type { AdminUser } from "./api";

// Shared admin-user display helpers, so the Roles and Moderation pages render names/roles identically.

export function shortId(id?: string | null) {
  return id ? `#${id.slice(0, 8)}` : "—";
}

// Pretty-print a phone: +91 83770 03300 for a 12-digit +91 number, else a sensible +digits form.
export function formatPhone(raw?: string | null) {
  if (!raw) return "";
  const digits = raw.replace(/\D/g, "");
  if (digits.length === 12 && digits.startsWith("91")) {
    return `+91 ${digits.slice(2, 7)} ${digits.slice(7)}`;
  }
  return raw.startsWith("+") ? raw : `+${digits}`;
}

// A user's display title: name → formatted phone → email → short id.
export function userTitle(
  u: Pick<AdminUser, "display_name" | "phone_number" | "email" | "user_id">
) {
  return u.display_name?.trim() || formatPhone(u.phone_number) || u.email?.trim() || shortId(u.user_id);
}

// The user's actual IAM role (root/admin/moderator/support/user); falls back to the legacy is_admin
// derivation only if role is absent.
export function roleLabel(u: Pick<AdminUser, "role" | "is_admin">) {
  return u.role || (u.is_admin ? "admin" : "user");
}

// Hierarchy rank (higher = more privileged), mirroring SharedInfra.IAM. Used to hide moderation actions
// on targets at/above the viewer's role. The BACKEND still enforces this — the UI hiding is only UX.
const ROLE_RANK: Record<string, number> = { root: 4, admin: 3, moderator: 2, support: 1, user: 0 };

export function roleRank(role?: string | null) {
  return ROLE_RANK[role ?? "user"] ?? 0;
}
