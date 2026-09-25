import type { AdminUser } from "./api";

// Shared admin-user display helpers, so every list renders a person the same way.
//
// THE RULE: a person is shown by NAME, else by @HANDLE, else as "(no name)". A phone number is never
// a title — it is secondary, and MASKED, everywhere except the user's own detail drawer. Before
// this, five pages each had their own "name || phone || id" fallback, so anyone who had not set a
// display name appeared as a bare phone number on every list in the console.

export function shortId(id?: string | null) {
  return id ? `#${id.slice(0, 8)}` : "—";
}

// Pretty-print a FULL phone: +91 83770 03300 for a 12-digit +91 number, else a sensible +digits form.
// For the detail drawer only — every list uses maskPhone.
export function formatPhone(raw?: string | null) {
  if (!raw) return "";
  const digits = raw.replace(/\D/g, "");
  if (digits.length === 12 && digits.startsWith("91")) {
    return `+91 ${digits.slice(2, 7)} ${digits.slice(7)}`;
  }
  return raw.startsWith("+") ? raw : `+${digits}`;
}

// "+91 •••••• 3300": the country code and the last four digits, everything between hidden. Enough
// to tell two people apart in a list, not enough to dial.
export function maskPhone(raw?: string | null): string {
  if (!raw) return "";
  const digits = raw.replace(/\D/g, "");
  if (digits.length === 0) return "";
  if (digits.length < 7) return "•".repeat(digits.length);

  const cc =
    digits.length === 11 && digits.startsWith("1")
      ? "1"
      : digits.length === 12 && digits.startsWith("91")
        ? "91"
        : digits.slice(0, 2);
  const last4 = digits.slice(-4);
  const hidden = Math.max(3, digits.length - cc.length - 4);
  return `+${cc} ${"•".repeat(hidden)} ${last4}`;
}

export type Identity = {
  display_name?: string | null;
  username?: string | null;
  phone_number?: string | null;
  user_id?: string | null;
};

// name → @username → "(no name)". Never a phone, never an email, never a raw id.
export function identityTitle(i: Identity | null | undefined): string {
  const name = i?.display_name?.trim();
  if (name) return name;
  const handle = i?.username?.trim().replace(/^@/, "");
  if (handle) return `@${handle}`;
  return "(no name)";
}

// The line under a title: the handle when the title is a name (so it is not shown twice), and the
// masked phone. Empty when there is nothing safe to add.
export function identitySubtitle(i: Identity | null | undefined): string {
  const parts: string[] = [];
  const handle = i?.username?.trim().replace(/^@/, "");
  if (handle && i?.display_name?.trim()) parts.push(`@${handle}`);
  const phone = maskPhone(i?.phone_number);
  if (phone) parts.push(phone);
  return parts.join(" · ");
}

// A user's display title, for the list rows that already used this name.
export function userTitle(u: Pick<AdminUser, "display_name" | "username">) {
  return identityTitle(u);
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
