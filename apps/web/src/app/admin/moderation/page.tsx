"use client";

import { useCallback, useEffect, useState } from "react";
import { AlertTriangle, Ban, Loader2, RotateCcw, ScrollText, ShieldAlert, UserX } from "lucide-react";
import {
  AdminReport,
  AdminUser,
  AuditEntry,
  banUser,
  getAdminAudit,
  getAdminReports,
  getAdminUsers,
  getCurrentSession,
  reactivateUser,
  suspendUser,
  updateReportStatus
} from "@/lib/api";
import { Avatar, Button, Card } from "@/components";
import { cn } from "@/lib/cn";
import { roleLabel, roleRank, userTitle } from "@/lib/adminUser";
import { UserDetailDrawer } from "./UserDetailDrawer";

// A viewer may moderate a target only if strictly higher-ranked, and never themselves (backend enforces).
function canModerate(
  viewer: { role?: string | null; user_id?: string } | null,
  target: AdminUser
) {
  if (!viewer) return false;
  if (viewer.user_id && viewer.user_id === target.user_id) return false;
  return roleRank(viewer.role) > roleRank(target.role);
}

type Tab = "users" | "reports" | "audit";

function StatusBadge({ status }: { status: string }) {
  const tone =
    status === "active"
      ? "bg-success/15 text-success"
      : status === "deleted"
        ? "bg-faint/20 text-faint"
        : "bg-danger/15 text-danger";
  return (
    <span className={cn("inline-flex rounded-full px-2 py-0.5 text-[11px] font-medium capitalize", tone)}>
      {status}
    </span>
  );
}

function shortId(id?: string | null) {
  return id ? `#${id.slice(0, 8)}` : "—";
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

function ConfirmDialog({
  open,
  title,
  body,
  confirmLabel,
  onConfirm,
  onCancel,
  busy
}: {
  open: boolean;
  title: string;
  body: string;
  confirmLabel: string;
  onConfirm: () => void;
  onCancel: () => void;
  busy: boolean;
}) {
  if (!open) return null;
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 animate-fade-in">
      <Card className="w-full max-w-sm p-6 animate-scale-in">
        <div className="mb-3 flex items-center gap-2 text-danger">
          <AlertTriangle className="h-5 w-5" />
          <h3 className="text-sm font-semibold text-fg">{title}</h3>
        </div>
        <p className="mb-5 text-sm text-muted">{body}</p>
        <div className="flex justify-end gap-2">
          <Button variant="ghost" size="sm" onClick={onCancel} disabled={busy}>
            Cancel
          </Button>
          <Button variant="danger" size="sm" onClick={onConfirm} isLoading={busy}>
            {confirmLabel}
          </Button>
        </div>
      </Card>
    </div>
  );
}

export default function AdminModerationPage() {
  const [tab, setTab] = useState<Tab>("users");
  const [toast, setToast] = useState<{ tone: "ok" | "err"; msg: string } | null>(null);

  const flash = useCallback((tone: "ok" | "err", msg: string) => {
    setToast({ tone, msg });
    setTimeout(() => setToast(null), 2600);
  }, []);

  return (
    <div className="mx-auto max-w-5xl animate-fade-in">
      <Toast toast={toast} />
      <h2 className="text-xl font-semibold text-fg">Moderation</h2>
      <p className="mb-5 text-sm text-muted">Manage users, review reports, and audit admin actions.</p>

      <div className="mb-5 flex gap-1 border-b border-border">
        {([
          ["users", "Users", UserX],
          ["reports", "Reports", ShieldAlert],
          ["audit", "Audit log", ScrollText]
        ] as const).map(([key, label, Icon]) => (
          <button
            key={key}
            type="button"
            onClick={() => setTab(key)}
            className={cn(
              "flex items-center gap-2 border-b-2 px-3 py-2 text-sm font-medium transition-colors",
              tab === key
                ? "border-brand text-fg"
                : "border-transparent text-muted hover:text-fg"
            )}
          >
            <Icon className="h-4 w-4" />
            {label}
          </button>
        ))}
      </div>

      {tab === "users" && <UsersTab flash={flash} />}
      {tab === "reports" && <ReportsTab flash={flash} />}
      {tab === "audit" && <AuditTab />}
    </div>
  );
}

type Flash = (tone: "ok" | "err", msg: string) => void;

function UsersTab({ flash }: { flash: Flash }) {
  const [users, setUsers] = useState<AdminUser[]>([]);
  const [q, setQ] = useState("");
  const [statusFilter, setStatusFilter] = useState("");
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState("");
  const [confirm, setConfirm] = useState<{ user: AdminUser } | null>(null);
  const [selectedUserId, setSelectedUserId] = useState<string | null>(null);
  // The viewer's role + id gate which rows are moderatable (UX only — backend enforces the hierarchy).
  const [viewer, setViewer] = useState<{ role?: string | null; user_id?: string } | null>(null);

  useEffect(() => {
    getCurrentSession()
      .then((s) => setViewer({ role: s.role, user_id: s.user_id }))
      .catch(() => setViewer(null));
  }, []);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await getAdminUsers({ q: q.trim() || undefined, status: statusFilter || undefined });
      setUsers(res.users);
    } catch (e) {
      flash("err", e instanceof Error ? e.message : "Failed to load users");
    } finally {
      setLoading(false);
    }
  }, [q, statusFilter, flash]);

  useEffect(() => {
    void load();
  }, [load]);

  async function act(user: AdminUser, action: "suspend" | "reactivate") {
    setBusyId(user.user_id);
    try {
      if (action === "suspend") await suspendUser(user.user_id, "Suspended via admin console");
      else await reactivateUser(user.user_id);
      flash("ok", `User ${action === "suspend" ? "suspended" : "reactivated"}`);
      await load();
    } catch (e) {
      flash("err", e instanceof Error ? e.message : "Action failed");
    } finally {
      setBusyId("");
    }
  }

  async function confirmBan() {
    if (!confirm) return;
    const user = confirm.user;
    setBusyId(user.user_id);
    try {
      await banUser(user.user_id, "Banned via admin console");
      flash("ok", "User banned");
      setConfirm(null);
      await load();
    } catch (e) {
      flash("err", e instanceof Error ? e.message : "Ban failed");
    } finally {
      setBusyId("");
    }
  }

  return (
    <div>
      <div className="mb-3 flex flex-wrap gap-2">
        <input
          className="h-9 w-56 rounded-lg border border-border bg-elevated px-3 text-sm text-fg placeholder:text-faint outline-none focus:border-brand focus:ring-2 focus:ring-brand-ring"
          placeholder="Search by phone or email…"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && load()}
        />
        <select
          className="h-9 rounded-lg border border-border bg-elevated px-3 text-sm text-fg outline-none focus:border-brand"
          value={statusFilter}
          onChange={(e) => setStatusFilter(e.target.value)}
        >
          <option value="">All statuses</option>
          <option value="active">Active</option>
          <option value="suspended">Suspended</option>
          <option value="deleted">Deleted</option>
        </select>
        <Button size="sm" variant="ghost" className="border border-border" onClick={load}>
          Search
        </Button>
      </div>

      {loading ? (
        <Loading />
      ) : users.length === 0 ? (
        <Empty text="No users found." />
      ) : (
        <Card className="divide-y divide-border">
          {users.map((u) => (
            <div key={u.user_id} className="flex items-center gap-3 p-3">
              <button
                type="button"
                onClick={() => setSelectedUserId(u.user_id)}
                className="flex min-w-0 flex-1 items-center gap-3 rounded-lg text-left transition-colors hover:opacity-80"
                title="View profile"
              >
                <Avatar id={u.user_id} name={userTitle(u)} size="sm" />
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium text-fg">
                    {userTitle(u)}
                    <span className="ml-2 rounded-full bg-brand-subtle/60 px-1.5 py-0.5 text-[10px] font-medium text-brand-hover">
                      {roleLabel(u)}
                    </span>
                  </p>
                  <p className="truncate text-xs text-faint">{shortId(u.user_id)}</p>
                </div>
              </button>
              <StatusBadge status={u.status} />
              {/* Only show moderation actions on a target STRICTLY below the viewer's role (never self). */}
              {canModerate(viewer, u) ? (
                <div className="flex gap-1">
                  {u.status === "active" ? (
                    <Button
                      size="sm"
                      variant="ghost"
                      onClick={() => act(u, "suspend")}
                      isLoading={busyId === u.user_id}
                      leftIcon={<UserX className="h-4 w-4" />}
                    >
                      Suspend
                    </Button>
                  ) : (
                    <Button
                      size="sm"
                      variant="ghost"
                      onClick={() => act(u, "reactivate")}
                      isLoading={busyId === u.user_id}
                      leftIcon={<RotateCcw className="h-4 w-4" />}
                    >
                      Reactivate
                    </Button>
                  )}
                  <Button
                    size="sm"
                    variant="danger"
                    onClick={() => setConfirm({ user: u })}
                    disabled={busyId === u.user_id}
                    leftIcon={<Ban className="h-4 w-4" />}
                  >
                    Ban
                  </Button>
                </div>
              ) : null}
            </div>
          ))}
        </Card>
      )}

      <ConfirmDialog
        open={Boolean(confirm)}
        title="Ban this user?"
        body={`This permanently suspends ${confirm?.user.phone_number || confirm?.user.email || shortId(confirm?.user.user_id)} and blocks them from authenticating. It's reversible via Reactivate.`}
        confirmLabel="Ban user"
        onConfirm={confirmBan}
        onCancel={() => setConfirm(null)}
        busy={Boolean(confirm) && busyId === confirm?.user.user_id}
      />

      {selectedUserId ? (
        <UserDetailDrawer
          userId={selectedUserId}
          onClose={() => setSelectedUserId(null)}
          onChanged={load}
          flash={flash}
        />
      ) : null}
    </div>
  );
}

function ReportsTab({ flash }: { flash: Flash }) {
  const [reports, setReports] = useState<AdminReport[]>([]);
  const [statusFilter, setStatusFilter] = useState("");
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState("");

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await getAdminReports({ status: statusFilter || undefined });
      setReports(res.reports);
    } catch (e) {
      flash("err", e instanceof Error ? e.message : "Failed to load reports");
    } finally {
      setLoading(false);
    }
  }, [statusFilter, flash]);

  useEffect(() => {
    void load();
  }, [load]);

  async function setStatus(report: AdminReport, status: string) {
    setBusyId(report.id);
    try {
      await updateReportStatus(report.id, status);
      flash("ok", `Report marked ${status}`);
      await load();
    } catch (e) {
      flash("err", e instanceof Error ? e.message : "Update failed");
    } finally {
      setBusyId("");
    }
  }

  return (
    <div>
      <div className="mb-3 flex gap-2">
        <select
          className="h-9 rounded-lg border border-border bg-elevated px-3 text-sm text-fg outline-none focus:border-brand"
          value={statusFilter}
          onChange={(e) => setStatusFilter(e.target.value)}
        >
          <option value="">All statuses</option>
          <option value="open">Open</option>
          <option value="reviewing">Reviewing</option>
          <option value="resolved">Resolved</option>
          <option value="dismissed">Dismissed</option>
        </select>
      </div>

      {loading ? (
        <Loading />
      ) : reports.length === 0 ? (
        <Empty text="No reports. The queue is clear." />
      ) : (
        <Card className="divide-y divide-border">
          {reports.map((r) => (
            <div key={r.id} className="p-3">
              <div className="flex items-center justify-between gap-2">
                <p className="text-sm font-medium text-fg">{r.reason}</p>
                <StatusBadge status={r.status} />
              </div>
              <p className="mt-1 text-xs text-muted">
                reporter {shortId(r.reporter_user_id)} → target {shortId(r.reported_user_id)}
              </p>
              {r.details ? <p className="mt-1 text-sm text-muted">{r.details}</p> : null}
              <div className="mt-2 flex gap-1">
                <Button size="sm" variant="ghost" onClick={() => setStatus(r, "reviewing")} isLoading={busyId === r.id}>
                  Reviewing
                </Button>
                <Button size="sm" variant="ghost" onClick={() => setStatus(r, "resolved")} isLoading={busyId === r.id}>
                  Resolve
                </Button>
                <Button size="sm" variant="ghost" onClick={() => setStatus(r, "dismissed")} isLoading={busyId === r.id}>
                  Dismiss
                </Button>
              </div>
            </div>
          ))}
        </Card>
      )}
    </div>
  );
}

function AuditTab() {
  const [entries, setEntries] = useState<AuditEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  useEffect(() => {
    let active = true;
    getAdminAudit(1)
      .then((res) => active && setEntries(res.entries))
      .catch((e) => active && setError(e instanceof Error ? e.message : "Failed to load audit log"))
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, []);

  if (loading) return <Loading />;
  if (error) return <Empty text={error} />;
  if (entries.length === 0) return <Empty text="No admin actions recorded yet." />;

  return (
    <Card className="divide-y divide-border">
      {entries.map((e, i) => (
        <div key={i} className="flex items-center gap-3 p-3">
          <ScrollText className="h-4 w-4 shrink-0 text-faint" />
          <div className="min-w-0 flex-1">
            <p className="truncate text-sm text-fg">
              <span className="font-medium">{e.action}</span>{" "}
              <span className="text-muted">
                {e.target_type} {shortId(e.target_id)}
              </span>
            </p>
            <p className="truncate text-xs text-faint">by {shortId(e.actor_user_id)}</p>
          </div>
          <span className="shrink-0 text-xs text-faint">{e.created_at}</span>
        </div>
      ))}
    </Card>
  );
}

function Loading() {
  return (
    <div className="flex h-32 items-center justify-center text-muted">
      <Loader2 className="mr-2 h-5 w-5 animate-spin" /> Loading…
    </div>
  );
}

function Empty({ text }: { text: string }) {
  return (
    <Card className="p-10 text-center text-sm text-muted">{text}</Card>
  );
}
