"use client";

import { useCallback, useEffect, useState } from "react";
import { AlertTriangle, Ban, Loader2, RotateCcw, ScrollText, ShieldAlert, UserX } from "lucide-react";
import Link from "next/link";
import { Pager } from "@/app/admin/_Pager";
import { StepUpDialog } from "@/app/admin/_StepUpDialog";
import { isWaiting, reportAge } from "@/lib/adminDashboard";
import { usePaging } from "@/app/admin/_usePaging";
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
import { formatPhone, roleLabel, roleRank, userTitle } from "@/lib/adminUser";
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

// "" is every status. Open first, because that is what somebody opening this tab came to do.
const REPORT_FILTERS = [
  { value: "open", label: "Open" },
  { value: "reviewing", label: "Reviewing" },
  { value: "resolved", label: "Resolved" },
  { value: "dismissed", label: "Dismissed" },
  { value: "", label: "All" }
] as const;

function UsersTab({ flash }: { flash: Flash }) {
  const [users, setUsers] = useState<AdminUser[]>([]);
  const [q, setQ] = useState("");
  const [statusFilter, setStatusFilter] = useState("");
  const paging = usePaging("moderation.users");
  const { params: pageParams, setEnvelope } = paging;
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
      const res = await getAdminUsers({
        q: q.trim() || undefined,
        status: statusFilter || undefined,
        // The filters go back with EVERY page, so page 2 of "suspended" is still suspended users.
        ...pageParams
      });
      setUsers(res.users);
      setEnvelope(res);
    } catch (e) {
      flash("err", e instanceof Error ? e.message : "Failed to load users");
    } finally {
      setLoading(false);
    }
  }, [q, statusFilter, pageParams, setEnvelope, flash]);

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

  // Receives the step-up proof from the dialog. The SERVER requires it — without a valid, unexpired
  // token belonging to this admin, the ban endpoint answers 403 admin.reauth_required, so there is
  // no path to a ban that skips this by talking to the API directly.
  async function confirmBan(reauthToken: string) {
    if (!confirm) return;
    const user = confirm.user;
    setBusyId(user.user_id);
    try {
      await banUser(user.user_id, "Banned via admin console", reauthToken);
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
          onChange={(e) => {
            setQ(e.target.value);
            // A cursor names a row in the OLD result set — carrying it into a newly filtered list
            // would drop the reader on an arbitrary, usually empty, page.
            paging.reset();
          }}
          onKeyDown={(e) => e.key === "Enter" && load()}
        />
        <select
          className="h-9 rounded-lg border border-border bg-elevated px-3 text-sm text-fg outline-none focus:border-brand"
          value={statusFilter}
          onChange={(e) => {
            setStatusFilter(e.target.value);
            paging.reset();
          }}
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

      <Pager paging={paging} disabled={loading} />

      <StepUpDialog
        open={Boolean(confirm)}
        title="Ban this user?"
        body="This permanently suspends the account and blocks it from authenticating. It's reversible via Reactivate."
        confirmLabel="Ban user"
        target={confirm?.user ?? null}
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
  // The queue opens on OPEN reports, not on everything. A moderator arriving at this tab is here to
  // work the queue; showing resolved and dismissed rows first makes them filter before they can start.
  const [statusFilter, setStatusFilter] = useState("open");
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState("");
  const paging = usePaging("moderation.reports");
  const { params: pageParams, setEnvelope } = paging;
  const [selectedUserId, setSelectedUserId] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const res = await getAdminReports({
        status: statusFilter || undefined,
        ...pageParams
      });
      setReports(res.reports);
      setEnvelope(res);
    } catch (e) {
      flash("err", e instanceof Error ? e.message : "Failed to load reports");
    } finally {
      setLoading(false);
    }
  }, [statusFilter, pageParams, setEnvelope, flash]);

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
      {/* Status as CHIPS, not a dropdown. The queue's whole job is to be worked through, and a chip
          row shows what the current view is without opening anything. */}
      <div className="mb-3 flex flex-wrap items-center gap-1.5">
        {REPORT_FILTERS.map(({ value, label }) => (
          <button
            key={value || "all"}
            type="button"
            onClick={() => {
              setStatusFilter(value);
              paging.reset();
            }}
            className={cn(
              "h-8 rounded-full border px-3 text-xs font-medium transition-colors",
              statusFilter === value
                ? "border-brand bg-brand/10 text-fg"
                : "border-border text-muted hover:text-fg"
            )}
          >
            {label}
          </button>
        ))}
        <button
          type="button"
          onClick={() => void load()}
          className="ml-auto text-xs text-muted transition-colors hover:text-fg"
        >
          Refresh
        </button>
      </div>

      {loading ? (
        <Loading />
      ) : reports.length === 0 ? (
        <Empty
          text={
            statusFilter === "open"
              ? "No open reports. The queue is clear."
              : "No reports match this filter."
          }
        />
      ) : (
        <Card className="divide-y divide-border">
          {reports.map((r) => (
            <div
              key={r.id}
              className={cn(
                "p-3",
                // A row still waiting gets a left edge. Scanning a mixed list for what is unfinished
                // is the thing a queue should not make anybody do.
                isWaiting(r.status) && "border-l-2 border-l-brand"
              )}
            >
              <div className="flex items-center justify-between gap-2">
                <p className="text-sm font-medium text-fg">{r.reason}</p>
                <div className="flex shrink-0 items-center gap-2">
                  <span className="text-xs text-faint">{reportAge(r.created_at)}</span>
                  <StatusBadge status={r.status} />
                </div>
              </div>
              <p className="mt-1 text-xs text-muted">
                reporter{" "}
                <span title={r.reporter_user_id ?? undefined}>
                  {r.reporter_name?.trim() ||
                    formatPhone(r.reporter_phone) ||
                    shortId(r.reporter_user_id)}
                </span>{" "}
                → target{" "}
                {r.reported_user_id ? (
                  // Act on the PERSON from the row. Copying a UUID into the users tab to suspend
                  // somebody is the step that makes a queue feel like paperwork.
                  <button
                    type="button"
                    onClick={() => setSelectedUserId(r.reported_user_id ?? null)}
                    className="text-brand-hover underline-offset-2 hover:underline"
                    title={r.reported_user_id}
                  >
                    {r.reported_name?.trim() ||
                      formatPhone(r.reported_phone) ||
                      shortId(r.reported_user_id)}
                  </button>
                ) : (
                  <span className="italic text-faint">deleted user</span>
                )}
              </p>
              {r.details ? <p className="mt-1 text-sm text-muted">{r.details}</p> : null}
              <div className="mt-2 flex flex-wrap items-center gap-1">
                <Button
                  size="sm"
                  variant="ghost"
                  disabled={r.status === "reviewing"}
                  onClick={() => setStatus(r, "reviewing")}
                  isLoading={busyId === r.id}
                >
                  Reviewing
                </Button>
                <Button size="sm" variant="ghost" onClick={() => setStatus(r, "resolved")} isLoading={busyId === r.id}>
                  Resolve
                </Button>
                <Button size="sm" variant="ghost" onClick={() => setStatus(r, "dismissed")} isLoading={busyId === r.id}>
                  Dismiss
                </Button>
                {r.conversation_id ? (
                  <Link
                    href="/admin/content"
                    className="ml-1 text-xs text-muted transition-colors hover:text-fg"
                    title={r.conversation_id}
                  >
                    Open in content viewer
                  </Link>
                ) : null}
              </div>
            </div>
          ))}
        </Card>
      )}

      <Pager paging={paging} disabled={loading} />

      {selectedUserId ? (
        <UserDetailDrawer
          userId={selectedUserId}
          onClose={() => setSelectedUserId(null)}
          onChanged={() => void load()}
          flash={flash}
        />
      ) : null}
    </div>
  );
}

function AuditTab() {
  const [entries, setEntries] = useState<AuditEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const paging = usePaging("moderation.audit");
  const { params: pageParams, setEnvelope } = paging;

  useEffect(() => {
    let active = true;
    // Deliberately no synchronous setLoading here: the rows for the page you are leaving stay on
    // screen until the next page arrives, which is steadier than a full-height spinner between
    // every click, and it keeps this effect free of a synchronous state write.
    getAdminAudit(pageParams)
      .then((res) => {
        if (!active) return;
        setEntries(res.entries);
        setEnvelope(res);
      })
      .catch((e) => active && setError(e instanceof Error ? e.message : "Failed to load audit log"))
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [pageParams, setEnvelope]);

  if (loading) return <Loading />;
  if (error) return <Empty text={error} />;
  if (entries.length === 0) return <Empty text="No admin actions recorded yet." />;

  return (
    <>
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
            <p className="truncate text-xs text-faint" title={e.actor_user_id ?? undefined}>
              by {e.actor_name?.trim() || formatPhone(e.actor_phone) || shortId(e.actor_user_id)}
              {/* Where the action came from. An audit row recording who and what but not from
                  where cannot answer the question it exists for. */}
              {e.ip_address ? <span> · {e.ip_address}</span> : null}
            </p>
          </div>
          <span className="shrink-0 text-xs text-faint">{e.created_at}</span>
        </div>
      ))}
      </Card>

      <Pager paging={paging} disabled={loading} />
    </>
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
