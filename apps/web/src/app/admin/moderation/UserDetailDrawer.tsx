"use client";

import { useCallback, useEffect, useState } from "react";
import {
  Ban,
  Clock,
  Database,
  HardDrive,
  Loader2,
  MessageSquare,
  MessagesSquare,
  RotateCcw,
  ShieldAlert,
  UserX,
  X
} from "lucide-react";
import {
  AdminReport,
  AdminUserDetail,
  banUser,
  getAdminUser,
  reactivateUser,
  suspendUser
} from "@/lib/api";
import { Avatar, Button, Card } from "@/components";
import { cn } from "@/lib/cn";

type Flash = (tone: "ok" | "err", msg: string) => void;

function shortId(id?: string | null) {
  return id ? `#${id.slice(0, 8)}` : "—";
}

function formatBytes(bytes: number) {
  if (!bytes) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  const i = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
  return `${(bytes / Math.pow(1024, i)).toFixed(i === 0 ? 0 : 1)} ${units[i]}`;
}

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

function Stat({
  icon: Icon,
  label,
  value
}: {
  icon: typeof Database;
  label: string;
  value: string;
}) {
  return (
    <Card className="p-3">
      <div className="flex items-center gap-2 text-faint">
        <Icon className="h-4 w-4" />
        <span className="text-[11px] font-medium uppercase tracking-wide">{label}</span>
      </div>
      <p className="mt-1 text-lg font-semibold text-fg">{value}</p>
    </Card>
  );
}

function ReportList({ title, reports }: { title: string; reports: AdminReport[] }) {
  return (
    <div>
      <p className="mb-1.5 text-xs font-medium uppercase tracking-wide text-faint">{title}</p>
      {reports.length === 0 ? (
        <p className="text-sm text-muted">None.</p>
      ) : (
        <ul className="space-y-1">
          {reports.map((r) => (
            <li key={r.id} className="rounded-lg border border-border bg-elevated px-3 py-2">
              <div className="flex items-center justify-between gap-2">
                <span className="text-sm text-fg">{r.reason}</span>
                <span className="text-[11px] capitalize text-faint">{r.status}</span>
              </div>
              <p className="text-xs text-faint">{r.created_at}</p>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

export function UserDetailDrawer({
  userId,
  onClose,
  onChanged,
  flash
}: {
  userId: string;
  onClose: () => void;
  onChanged: () => void;
  flash: Flash;
}) {
  const [detail, setDetail] = useState<AdminUserDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [confirmBan, setConfirmBan] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setDetail(await getAdminUser(userId));
      setError("");
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load user");
    } finally {
      setLoading(false);
    }
  }, [userId]);

  useEffect(() => {
    void load();
  }, [load]);

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") onClose();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  async function act(action: "suspend" | "reactivate" | "ban") {
    setBusy(true);
    try {
      if (action === "suspend") await suspendUser(userId, "Suspended via admin console");
      else if (action === "reactivate") await reactivateUser(userId);
      else await banUser(userId, "Banned via admin console");
      flash("ok", `User ${action === "reactivate" ? "reactivated" : action + "ned"}`);
      setConfirmBan(false);
      await load();
      onChanged();
    } catch (e) {
      flash("err", e instanceof Error ? e.message : "Action failed");
    } finally {
      setBusy(false);
    }
  }

  const auth = detail?.auth;
  const profile = detail?.profile;
  const stats = detail?.stats;
  const name = profile?.display_name || auth?.phone_number || auth?.email || shortId(userId);

  return (
    <div className="fixed inset-0 z-30 flex justify-end">
      <button type="button" aria-label="Close" onClick={onClose} className="absolute inset-0 bg-black/50 animate-fade-in" />

      <aside className="relative flex h-full w-full flex-col border-l border-border bg-surface shadow-elevated animate-slide-in-right sm:w-[28rem]">
        <header className="flex items-center justify-between border-b border-border px-4 py-3">
          <h3 className="text-sm font-semibold text-fg">User detail</h3>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close"
            className="rounded-lg p-1.5 text-muted transition-colors hover:bg-elevated hover:text-fg"
          >
            <X className="h-5 w-5" />
          </button>
        </header>

        {loading ? (
          <div className="flex flex-1 items-center justify-center text-muted">
            <Loader2 className="mr-2 h-5 w-5 animate-spin" /> Loading…
          </div>
        ) : error || !detail || !auth || !stats ? (
          <div className="flex flex-1 items-center justify-center px-6 text-center text-sm text-danger">
            {error || "No data."}
          </div>
        ) : (
          <div className="flex-1 space-y-5 overflow-y-auto p-4">
            {/* Identity */}
            <div className="flex items-center gap-3">
              <Avatar id={userId} name={name} size="lg" />
              <div className="min-w-0">
                <div className="flex items-center gap-2">
                  <p className="truncate text-base font-semibold text-fg">{name}</p>
                  <StatusBadge status={auth.status} />
                  {auth.is_admin ? (
                    <span className="rounded-full bg-brand-subtle/60 px-1.5 py-0.5 text-[10px] font-medium text-brand-hover">
                      admin
                    </span>
                  ) : null}
                </div>
                <p className="truncate text-xs text-faint">
                  {auth.phone_number || auth.email || shortId(userId)} · member since{" "}
                  {auth.created_at?.slice(0, 10) ?? "—"}
                </p>
                {profile?.bio ? <p className="mt-1 text-sm text-muted">{profile.bio}</p> : null}
              </div>
            </div>

            {/* Inline moderation actions */}
            <div className="flex flex-wrap gap-2">
              {auth.status === "active" ? (
                <Button size="sm" variant="ghost" className="border border-border" isLoading={busy} onClick={() => act("suspend")} leftIcon={<UserX className="h-4 w-4" />}>
                  Suspend
                </Button>
              ) : (
                <Button size="sm" variant="ghost" className="border border-border" isLoading={busy} onClick={() => act("reactivate")} leftIcon={<RotateCcw className="h-4 w-4" />}>
                  Reactivate
                </Button>
              )}
              <Button size="sm" variant="danger" disabled={busy} onClick={() => setConfirmBan(true)} leftIcon={<Ban className="h-4 w-4" />}>
                Ban
              </Button>
            </div>

            {/* Stats */}
            <div className="grid grid-cols-2 gap-2">
              <Stat icon={MessagesSquare} label="Conversations" value={String(stats.conversations)} />
              <Stat icon={MessageSquare} label="Messages" value={String(stats.messages_sent)} />
              <Stat icon={HardDrive} label="Media" value={String(stats.media)} />
              <Stat icon={Database} label="Storage" value={formatBytes(stats.storage_bytes)} />
            </div>
            <Card className="flex items-center gap-2 p-3 text-sm text-muted">
              <Clock className="h-4 w-4 text-faint" />
              Last active: {stats.last_active_at ? stats.last_active_at.replace("T", " ").replace("Z", " UTC") : "never"}
            </Card>

            {/* Enforcement history */}
            <div>
              <p className="mb-1.5 flex items-center gap-1.5 text-xs font-medium uppercase tracking-wide text-faint">
                <ShieldAlert className="h-3.5 w-3.5" /> Enforcement history
              </p>
              {detail.enforcement.length === 0 ? (
                <p className="text-sm text-muted">No enforcement actions.</p>
              ) : (
                <ul className="space-y-1">
                  {detail.enforcement.map((e, i) => (
                    <li key={i} className="rounded-lg border border-border bg-elevated px-3 py-2">
                      <div className="flex items-center justify-between gap-2">
                        <span className="rounded-full bg-danger/15 px-2 py-0.5 text-[11px] font-medium capitalize text-danger">
                          {e.action_type}
                        </span>
                        <span className="text-[11px] text-faint">{e.created_at}</span>
                      </div>
                      {e.reason ? <p className="mt-1 text-sm text-fg">{e.reason}</p> : null}
                      <p className="text-xs text-faint">by {shortId(e.action_by)}</p>
                    </li>
                  ))}
                </ul>
              )}
            </div>

            {/* Reports */}
            <div className="space-y-3">
              <ReportList title="Reports against this user" reports={detail.reports.against} />
              <ReportList title="Reports by this user" reports={detail.reports.by} />
            </div>
          </div>
        )}

        {confirmBan ? (
          <div className="absolute inset-0 z-10 flex items-center justify-center bg-black/60 p-4 animate-fade-in">
            <Card className="w-full max-w-xs p-5 animate-scale-in">
              <p className="mb-1 text-sm font-semibold text-fg">Ban this user?</p>
              <p className="mb-4 text-sm text-muted">Permanently suspends + blocks auth. Reversible via Reactivate.</p>
              <div className="flex justify-end gap-2">
                <Button size="sm" variant="ghost" onClick={() => setConfirmBan(false)} disabled={busy}>
                  Cancel
                </Button>
                <Button size="sm" variant="danger" isLoading={busy} onClick={() => act("ban")}>
                  Ban user
                </Button>
              </div>
            </Card>
          </div>
        ) : null}
      </aside>
    </div>
  );
}
