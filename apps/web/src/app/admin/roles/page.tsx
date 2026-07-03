"use client";

import { ReactNode, useCallback, useEffect, useState } from "react";
import { Loader2, Trash2 } from "lucide-react";
import {
  AdminUser,
  IAM_ROLES,
  IamRole,
  deleteUser,
  getAdminUsers,
  getCurrentSession,
  setUserRole
} from "@/lib/api";
import { Avatar, Button, Card } from "@/components";
import { cn } from "@/lib/cn";

// Pretty-print a phone: +91 83770 03300 for a 12-digit +91 number, else a sensible +digits form.
function formatPhone(raw?: string | null) {
  if (!raw) return "";
  const digits = raw.replace(/\D/g, "");
  if (digits.length === 12 && digits.startsWith("91")) {
    return `+91 ${digits.slice(2, 7)} ${digits.slice(7)}`;
  }
  return raw.startsWith("+") ? raw : `+${digits}`;
}

function labelOf(u: AdminUser) {
  return u.display_name?.trim() || formatPhone(u.phone_number) || u.email?.trim() || shortId(u.user_id);
}

function shortId(id?: string | null) {
  return id ? `#${id.slice(0, 8)}` : "—";
}

function Centered({ children }: { children: ReactNode }) {
  return <div className="flex items-center justify-center gap-2 py-16 text-muted">{children}</div>;
}

function Toast({ toast }: { toast: { tone: "ok" | "err"; msg: string } | null }) {
  if (!toast) return null;
  return (
    <div className="pointer-events-none fixed inset-x-0 top-4 z-50 flex justify-center px-4">
      <div
        className={cn(
          "rounded-full border px-4 py-2 text-sm font-medium shadow-elevated animate-slide-up",
          toast.tone === "ok"
            ? "border-success/40 bg-success/15 text-success"
            : "border-danger/40 bg-danger/15 text-danger"
        )}
      >
        {toast.msg}
      </div>
    </div>
  );
}

export default function AdminRolesPage() {
  // null = still checking; true/false = has roles.manage. Belt-and-suspenders even though the nav hides
  // this for non-root (backend also 403s the assignment endpoint).
  const [allowed, setAllowed] = useState<boolean | null>(null);
  // Permanent delete is a separate, stricter permission (users.delete — root only).
  const [canDelete, setCanDelete] = useState(false);
  const [confirmUser, setConfirmUser] = useState<AdminUser | null>(null);
  const [users, setUsers] = useState<AdminUser[]>([]);
  const [q, setQ] = useState("");
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState("");
  const [choice, setChoice] = useState<Record<string, string>>({});
  const [toast, setToast] = useState<{ tone: "ok" | "err"; msg: string } | null>(null);

  const flash = useCallback((tone: "ok" | "err", msg: string) => {
    setToast({ tone, msg });
    setTimeout(() => setToast(null), 3400);
  }, []);

  useEffect(() => {
    getCurrentSession()
      .then((s) => {
        const perms = s.permissions ?? [];
        setAllowed(perms.includes("roles.manage"));
        setCanDelete(perms.includes("users.delete"));
      })
      .catch(() => setAllowed(false));
  }, []);

  async function confirmDelete() {
    if (!confirmUser) return;
    const user = confirmUser;
    setBusyId(user.user_id);
    try {
      await deleteUser(user.user_id);
      flash("ok", `Deleted ${labelOf(user)}`);
      setUsers((us) => us.filter((u) => u.user_id !== user.user_id));
      setConfirmUser(null);
    } catch (e) {
      // Surfaces guard errors clearly (iam.cannot_delete_privileged / iam.cannot_delete_self).
      flash("err", e instanceof Error ? e.message : "Delete failed");
    } finally {
      setBusyId("");
    }
  }

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await getAdminUsers({ q: q.trim() || undefined });
      setUsers(res.users);
    } catch (e) {
      flash("err", e instanceof Error ? e.message : "Failed to load users");
    } finally {
      setLoading(false);
    }
  }, [q, flash]);

  useEffect(() => {
    if (allowed) void load();
  }, [allowed, load]);

  async function apply(user: AdminUser, role: string) {
    if (!role) return;
    setBusyId(user.user_id);
    try {
      const res = await setUserRole(user.user_id, role as IamRole);
      flash("ok", `${shortId(user.user_id)} is now ${res.role}`);
      // Optimistically reflect the new role (the users list doesn't return role from the backend yet).
      setUsers((us) =>
        us.map((u) =>
          u.user_id === user.user_id
            ? { ...u, role: res.role, is_admin: ["root", "admin"].includes(res.role) }
            : u
        )
      );
    } catch (e) {
      // Surfaces backend errors clearly, incl. the last-root guard (iam.last_root) and non-root 403s.
      flash("err", e instanceof Error ? e.message : "Role change failed");
    } finally {
      setBusyId("");
    }
  }

  if (allowed === null) {
    return (
      <Centered>
        <Loader2 className="h-5 w-5 animate-spin" aria-hidden /> Checking access…
      </Centered>
    );
  }

  if (!allowed) {
    return (
      <div className="mx-auto max-w-2xl animate-fade-in">
        <Card className="p-8 text-center text-muted">
          Role management requires the <span className="font-medium text-fg">roles.manage</span>{" "}
          permission (root only).
        </Card>
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-4xl animate-fade-in">
      <Toast toast={toast} />
      <h2 className="text-xl font-semibold text-fg">Roles</h2>
      <p className="mb-5 text-sm text-muted">
        Assign a role to a user. Root only. The last root can&apos;t be demoted — every change is audited.
      </p>

      <input
        value={q}
        onChange={(e) => setQ(e.target.value)}
        placeholder="Search users…"
        className="mb-4 h-10 w-full max-w-sm rounded-lg border border-border bg-elevated px-3 text-sm text-fg placeholder:text-faint outline-none focus:border-brand focus:ring-2 focus:ring-brand-ring"
      />

      {loading ? (
        <Centered>
          <Loader2 className="h-5 w-5 animate-spin" aria-hidden /> Loading users…
        </Centered>
      ) : (
        <Card className="divide-y divide-border/60 p-0">
          {users.map((u) => {
            // Dropdown defaults to the user's CURRENT role; Apply enables only on a real change.
            const selected = choice[u.user_id] ?? u.role ?? "";
            const name = u.display_name?.trim() || "";
            const phone = formatPhone(u.phone_number);
            const email = u.email?.trim() || "";
            // Prefer name → phone → email as the label; only fall back to the id when there's nothing else.
            const label = name || phone || email;
            const roleChip = u.role || (u.is_admin ? "admin" : "user");
            return (
              <div key={u.user_id} className="flex items-center gap-3 p-3">
                <Avatar id={u.user_id} name={label || u.user_id} size="sm" />
                <div className="min-w-0 flex-1">
                  <p
                    className={cn(
                      "truncate text-sm",
                      label ? "font-medium text-fg" : "font-mono text-muted"
                    )}
                  >
                    {label || shortId(u.user_id)}
                  </p>
                  <p className="mt-0.5 flex items-center gap-2 truncate text-xs text-faint">
                    {/* Show the phone in the subtitle when it isn't already the label. */}
                    {phone && phone !== label ? (
                      <span className="tabular-nums text-muted">{phone}</span>
                    ) : null}
                    {label ? <span>{shortId(u.user_id)}</span> : null}
                    <span className="rounded-full bg-brand-subtle px-1.5 py-0.5 font-medium text-brand-hover">
                      {roleChip}
                    </span>
                  </p>
                </div>
                <select
                  value={selected}
                  onChange={(e) => setChoice((c) => ({ ...c, [u.user_id]: e.target.value }))}
                  aria-label={`Role for ${label || shortId(u.user_id)}`}
                  className="h-9 rounded-lg border border-border bg-elevated px-2 text-sm text-fg outline-none focus:border-brand focus:ring-2 focus:ring-brand-ring"
                >
                  {IAM_ROLES.map((r) => (
                    <option key={r} value={r}>
                      {r}
                    </option>
                  ))}
                </select>
                <Button
                  size="sm"
                  onClick={() => apply(u, selected)}
                  disabled={!selected || selected === u.role}
                  isLoading={busyId === u.user_id}
                >
                  Apply
                </Button>
                {/* Delete: root-only (users.delete), and never offered for a root/admin (backend also rejects). */}
                {canDelete && !["root", "admin"].includes(u.role ?? "") ? (
                  <Button
                    size="sm"
                    variant="danger"
                    onClick={() => setConfirmUser(u)}
                    aria-label={`Delete ${label || shortId(u.user_id)}`}
                  >
                    <Trash2 className="h-4 w-4" aria-hidden />
                  </Button>
                ) : null}
              </div>
            );
          })}
          {users.length === 0 && (
            <div className="p-6 text-center text-sm text-muted">No users.</div>
          )}
        </Card>
      )}

      {/* Permanent-delete confirmation (names the user; this cannot be undone). */}
      {confirmUser ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <Card className="w-full max-w-sm p-6">
            <h3 className="text-base font-semibold text-fg">Permanently delete user?</h3>
            <p className="mt-2 text-sm text-muted">
              Permanently delete <span className="font-medium text-fg">{labelOf(confirmUser)}</span>?
              Their identity is removed and they can no longer sign in. Conversations they started are kept
              (reassigned to you) and their past messages remain, shown as “Deleted user.”{" "}
              <span className="font-medium text-danger">This cannot be undone.</span>
            </p>
            <div className="mt-5 flex justify-end gap-2">
              <Button
                size="sm"
                variant="ghost"
                onClick={() => setConfirmUser(null)}
                disabled={busyId === confirmUser.user_id}
              >
                Cancel
              </Button>
              <Button
                size="sm"
                variant="danger"
                onClick={confirmDelete}
                isLoading={busyId === confirmUser.user_id}
              >
                Delete permanently
              </Button>
            </div>
          </Card>
        </div>
      ) : null}
    </div>
  );
}
