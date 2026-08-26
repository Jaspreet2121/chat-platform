"use client";

import { useEffect, useState } from "react";
import {
  Bell,
  BellRing,
  ChevronRight,
  IndianRupee,
  Laptop,
  LogOut,
  MessageSquareReply,
  Moon,
  Pencil,
  Share,
  Shield,
  Smartphone,
  Star,
  Sun,
  UserPlus,
  Zap
} from "lucide-react";
import { useTheme } from "next-themes";
import {
  notificationSoundEnabled,
  setNotificationSoundEnabled
} from "./NotificationToasts";
import { enablePush, disablePush, getPushStatus, type PushStatus } from "@/lib/push";
import { listDevices, revokeDevice, type LinkedDevice, type Session, type UserProfile } from "@/lib/api";
import { getOrCreateDeviceId } from "@/lib/device";
import { Avatar } from "@/components";
import { cn } from "@/lib/cn";

export type ProfileTabProps = {
  session: Session | null;
  currentProfile: UserProfile | null;
  /** Opens the existing profile editor (name / about / avatar). */
  onEditProfile: () => void;
  onOpenStarred: () => void;
  /** Settings → Automated replies (102). */
  onOpenAutoReplies: () => void;
  /** Settings → Quick replies (100). */
  onOpenQuickReplies: () => void;
  /** Settings → Payments (100). */
  onOpenPayments: () => void;
  /** Focuses the phone search (the invite flow's entry point). */
  onInvite: () => void;
  onLogout: () => void;
};

function shortId(id?: string): string {
  return id ? `@${id.slice(0, 8)}` : "";
}

// Mobile "You" tab — a clean settings-style screen with ONLY the app's real features: profile editing,
// starred messages, theme, invite, the per-chat privacy pointer, and log out. (The old tab-bar settings
// menu's contents live here now.) Every row is backed by an existing handler — no dead buttons.
export function ProfileTab({
  session,
  currentProfile,
  onEditProfile,
  onOpenStarred,
  onOpenAutoReplies,
  onOpenQuickReplies,
  onOpenPayments,
  onInvite,
  onLogout
}: ProfileTabProps) {
  const { resolvedTheme, setTheme } = useTheme();
  const isDark = resolvedTheme === "dark";
  const [soundOn, setSoundOn] = useState(() => notificationSoundEnabled());
  // Web-push state (Phase 2). Resolved async on mount; every transition is user-gesture-driven.
  const [pushStatus, setPushStatus] = useState<PushStatus | null>(null);
  // Linked devices (099): loaded on mount; `current` is derived server-side from the session, but we
  // also compare against this browser's device_id as belt (both come from the same login).
  const [devices, setDevices] = useState<LinkedDevice[] | null>(null);
  const [devicesError, setDevicesError] = useState("");
  const [revokingId, setRevokingId] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    listDevices()
      .then((result) => {
        if (!cancelled) setDevices(result.devices ?? []);
      })
      .catch(() => {
        if (!cancelled) {
          setDevices([]);
          setDevicesError("Couldn't load linked devices.");
        }
      });

    return () => {
      cancelled = true;
    };
  }, []);

  const handleRevoke = async (deviceId: string) => {
    if (deviceId === getOrCreateDeviceId()) return; // belt: never revoke self here (Log out owns it)
    setRevokingId(deviceId);
    setDevicesError("");

    try {
      await revokeDevice(deviceId);
      setDevices((current) => (current ?? []).filter((d) => d.device_id !== deviceId));
    } catch {
      setDevicesError("Couldn't remove that device.");
    } finally {
      setRevokingId(null);
    }
  };
  const [pushBusy, setPushBusy] = useState(false);

  useEffect(() => {
    let active = true;
    void getPushStatus().then((status) => {
      if (active) setPushStatus(status);
    });
    return () => {
      active = false;
    };
  }, []);

  async function togglePush() {
    if (pushBusy || !pushStatus) return;
    setPushBusy(true);
    try {
      if (pushStatus === "enabled") {
        await disablePush();
        setPushStatus(await getPushStatus());
      } else {
        setPushStatus(await enablePush());
      }
    } catch {
      setPushStatus(await getPushStatus());
    } finally {
      setPushBusy(false);
    }
  }
  const name = currentProfile?.display_name?.trim() || "Set up your profile";

  return (
    <div className="flex h-full flex-col overflow-y-auto bg-bg pb-[calc(84px+env(safe-area-inset-bottom))]">
      {/* Identity hero: large avatar, name, handle, edit affordance */}
      <div className="flex flex-col items-center gap-3 px-6 pb-6 pt-8">
        <Avatar
          id={session?.user_id ?? "me"}
          name={currentProfile?.display_name ?? undefined}
          imageUrl={currentProfile?.avatar_url}
          size="lg"
          className="h-20 w-20 text-xl"
        />
        <div className="text-center">
          <h1 className="text-lg font-semibold tracking-[-0.02em] text-fg">{name}</h1>
          {session ? <p className="text-sm text-muted">{shortId(session.user_id)}</p> : null}
          {currentProfile?.bio?.trim() ? (
            <p className="mx-auto mt-1 max-w-[16rem] text-sm text-muted">{currentProfile.bio}</p>
          ) : null}
        </div>
        <button
          type="button"
          onClick={onEditProfile}
          className="accent-gradient inline-flex min-h-11 items-center gap-2 rounded-full px-5 py-2 text-sm font-medium text-white shadow-accent-glow transition-transform active:scale-95 outline-none focus-visible:ring-2 focus-visible:ring-brand-ring"
        >
          <Pencil className="h-4 w-4" aria-hidden />
          Edit profile
        </button>
      </div>

      <div className="space-y-4 px-4">
        {/* Group: content */}
        <section className="overflow-hidden rounded-2xl border border-border bg-surface shadow-subtle">
          <Row
            icon={<Star className="h-[18px] w-[18px]" aria-hidden />}
            label="Starred messages"
            onClick={onOpenStarred}
          />
          <Divider />
          <Row
            icon={<Zap className="h-[18px] w-[18px]" aria-hidden />}
            label="Quick replies"
            onClick={onOpenQuickReplies}
          />
          <Divider />
          <Row
            icon={<MessageSquareReply className="h-[18px] w-[18px]" aria-hidden />}
            label="Automated replies"
            onClick={onOpenAutoReplies}
          />
          <Divider />
          <Row
            icon={<IndianRupee className="h-[18px] w-[18px]" aria-hidden />}
            label="Payments"
            onClick={onOpenPayments}
          />
          <Divider />
          <Row
            icon={<UserPlus className="h-[18px] w-[18px]" aria-hidden />}
            label="Invite a friend"
            onClick={onInvite}
          />
        </section>

        {/* Group: appearance */}
        <section className="overflow-hidden rounded-2xl border border-border bg-surface shadow-subtle">
          <button
            type="button"
            onClick={() => setTheme(isDark ? "light" : "dark")}
            className="flex min-h-12 w-full items-center gap-3 px-4 py-3 text-left transition-colors hover:bg-elevated outline-none focus-visible:bg-elevated"
          >
            <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-brand-subtle text-brand-hover">
              {isDark ? (
                <Moon className="h-[18px] w-[18px]" aria-hidden />
              ) : (
                <Sun className="h-[18px] w-[18px]" aria-hidden />
              )}
            </span>
            <span className="flex-1 text-sm font-medium text-fg">Appearance</span>
            <span
              className={cn(
                "relative h-6 w-11 shrink-0 rounded-full transition-colors",
                isDark ? "accent-gradient" : "bg-border-strong"
              )}
              aria-hidden
            >
              <span
                className={cn(
                  "absolute top-0.5 h-5 w-5 rounded-full bg-white shadow-subtle transition-all",
                  isDark ? "left-[22px]" : "left-0.5"
                )}
              />
            </span>
            <span className="sr-only">{isDark ? "Switch to light mode" : "Switch to dark mode"}</span>
          </button>
          <div className="mx-4 h-px bg-border/60" aria-hidden />

          {/* Push notifications (app closed). States: toggle / blocked hint / iOS install hint /
              unsupported note. Never triggers a permission prompt without this tap. */}
          {pushStatus === "ios-needs-install" ? (
            <div className="flex items-start gap-3 px-4 py-3">
              <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-brand-subtle text-brand-hover">
                <Share className="h-[18px] w-[18px]" aria-hidden />
              </span>
              <div className="min-w-0">
                <p className="text-sm font-medium text-fg">Notifications on iPhone</p>
                <p className="mt-0.5 text-xs text-muted">
                  Add Growblic to your Home Screen to enable notifications: tap the Share button, then
                  &ldquo;Add to Home Screen&rdquo;, and open the app from there.
                </p>
              </div>
            </div>
          ) : pushStatus === "unsupported" ? (
            <div className="flex items-center gap-3 px-4 py-3">
              <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-brand-subtle text-brand-hover">
                <Bell className="h-[18px] w-[18px]" aria-hidden />
              </span>
              <p className="text-sm text-muted">Notifications aren&apos;t supported on this browser.</p>
            </div>
          ) : pushStatus === "blocked" ? (
            <div className="flex items-start gap-3 px-4 py-3">
              <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-brand-subtle text-brand-hover">
                <Bell className="h-[18px] w-[18px]" aria-hidden />
              </span>
              <div className="min-w-0">
                <p className="text-sm font-medium text-fg">Notifications blocked</p>
                <p className="mt-0.5 text-xs text-muted">
                  You&apos;ve blocked notifications for this site. Re-enable them in your browser&apos;s
                  site settings, then come back here.
                </p>
              </div>
            </div>
          ) : (
            <button
              type="button"
              onClick={() => void togglePush()}
              disabled={pushBusy || pushStatus === null}
              className="flex min-h-12 w-full items-center gap-3 px-4 py-3 text-left transition-colors hover:bg-elevated outline-none focus-visible:bg-elevated disabled:opacity-60"
            >
              <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-brand-subtle text-brand-hover">
                {pushStatus === "enabled" ? (
                  <BellRing className="h-[18px] w-[18px]" aria-hidden />
                ) : (
                  <Bell className="h-[18px] w-[18px]" aria-hidden />
                )}
              </span>
              <span className="min-w-0 flex-1">
                <span className="block text-sm font-medium text-fg">Notifications</span>
                <span className="block text-xs text-muted">
                  {pushStatus === "enabled"
                    ? "On — you'll get message alerts even when the app is closed"
                    : "Get message alerts even when the app is closed"}
                </span>
              </span>
              <span
                className={cn(
                  "relative h-6 w-11 shrink-0 rounded-full transition-colors",
                  pushStatus === "enabled" ? "accent-gradient" : "bg-border-strong"
                )}
                aria-hidden
              >
                <span
                  className={cn(
                    "absolute top-0.5 h-5 w-5 rounded-full bg-white shadow-subtle transition-all",
                    pushStatus === "enabled" ? "left-[22px]" : "left-0.5"
                  )}
                />
              </span>
              <span className="sr-only">
                {pushStatus === "enabled" ? "Turn notifications off" : "Turn notifications on"}
              </span>
            </button>
          )}

          <div className="mx-4 h-px bg-border/60" aria-hidden />
          <button
            type="button"
            onClick={() => {
              const next = !soundOn;
              setNotificationSoundEnabled(next);
              setSoundOn(next);
            }}
            className="flex min-h-12 w-full items-center gap-3 px-4 py-3 text-left transition-colors hover:bg-elevated outline-none focus-visible:bg-elevated"
          >
            <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-brand-subtle text-brand-hover">
              <Bell className="h-[18px] w-[18px]" aria-hidden />
            </span>
            <span className="flex-1 text-sm font-medium text-fg">Notification sound</span>
            <span
              className={cn(
                "relative h-6 w-11 shrink-0 rounded-full transition-colors",
                soundOn ? "accent-gradient" : "bg-border-strong"
              )}
              aria-hidden
            >
              <span
                className={cn(
                  "absolute top-0.5 h-5 w-5 rounded-full bg-white shadow-subtle transition-all",
                  soundOn ? "left-[22px]" : "left-0.5"
                )}
              />
            </span>
            <span className="sr-only">{soundOn ? "Turn sound off" : "Turn sound on"}</span>
          </button>
        </section>

        {/* Group: privacy — points at the real per-chat controls (clear chat / auto-delete). */}
        <section className="overflow-hidden rounded-2xl border border-border bg-surface shadow-subtle">
          <div className="flex items-start gap-3 px-4 py-3">
            <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-brand-subtle text-brand-hover">
              <Shield className="h-[18px] w-[18px]" aria-hidden />
            </span>
            <div className="min-w-0">
              <p className="text-sm font-medium text-fg">Privacy</p>
              <p className="mt-0.5 text-xs text-muted">
                Clear chat and auto-delete messages live in each chat — open a conversation and tap its
                name.
              </p>
            </div>
          </div>
        </section>

        {/* Linked devices (099) — this browser and everything else signed in. Revoke is offered only
            where the backend allows it: never THIS browser (Log out below owns that gesture) and
            never a PRIMARY phone session (the server 403s a linked device touching a primary). */}
        <section className="overflow-hidden rounded-2xl border border-border bg-surface shadow-subtle">
          <div className="flex items-start gap-3 px-4 py-3">
            <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-brand-subtle text-brand-hover">
              <Laptop className="h-[18px] w-[18px]" aria-hidden />
            </span>
            <div className="min-w-0 flex-1">
              <p className="text-sm font-medium text-fg">Linked devices</p>
              {devices === null ? (
                <p className="mt-0.5 text-xs text-muted">Loading…</p>
              ) : devices.length === 0 ? (
                <p className="mt-0.5 text-xs text-muted">Only this browser is signed in.</p>
              ) : (
                <ul className="mt-2 space-y-2">
                  {devices.map((device) => (
                    <li key={device.device_id} className="flex items-center gap-2 text-xs">
                      {device.platform === "web" ? (
                        <Laptop className="h-3.5 w-3.5 shrink-0 text-faint" aria-hidden />
                      ) : (
                        <Smartphone className="h-3.5 w-3.5 shrink-0 text-faint" aria-hidden />
                      )}
                      <span className="min-w-0 flex-1 truncate text-muted">
                        {device.device_name || device.platform}
                        {device.current ? (
                          <span className="ml-1.5 rounded bg-brand-subtle px-1.5 py-0.5 text-[10px] font-medium text-brand-hover">
                            This browser
                          </span>
                        ) : null}
                        {device.linked_by === null && device.platform !== "web" ? (
                          <span className="ml-1.5 rounded bg-elevated px-1.5 py-0.5 text-[10px] font-medium text-faint">
                            Primary
                          </span>
                        ) : null}
                      </span>
                      {!device.current && device.linked_by !== null ? (
                        <button
                          type="button"
                          onClick={() => void handleRevoke(device.device_id)}
                          disabled={revokingId === device.device_id}
                          className="shrink-0 font-medium text-danger hover:underline disabled:opacity-50"
                        >
                          {revokingId === device.device_id ? "Removing…" : "Remove"}
                        </button>
                      ) : null}
                    </li>
                  ))}
                </ul>
              )}
              {devicesError ? <p className="mt-1 text-xs text-danger">{devicesError}</p> : null}
            </div>
          </div>
        </section>

        {/* Log out — spatially separated, danger-toned */}
        <section className="overflow-hidden rounded-2xl border border-danger/30 bg-surface shadow-subtle">
          <button
            type="button"
            onClick={onLogout}
            className="flex min-h-12 w-full items-center gap-3 px-4 py-3 text-left transition-colors hover:bg-danger/5 outline-none focus-visible:bg-danger/5"
          >
            <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-danger/10 text-danger">
              <LogOut className="h-[18px] w-[18px]" aria-hidden />
            </span>
            <span className="text-sm font-medium text-danger">Log out</span>
          </button>
        </section>
      </div>
    </div>
  );
}

function Row({
  icon,
  label,
  onClick
}: {
  icon: React.ReactNode;
  label: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="flex min-h-12 w-full items-center gap-3 px-4 py-3 text-left transition-colors hover:bg-elevated outline-none focus-visible:bg-elevated"
    >
      <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-brand-subtle text-brand-hover">
        {icon}
      </span>
      <span className="min-w-0 flex-1 truncate text-sm font-medium text-fg">{label}</span>
      <ChevronRight className="h-4 w-4 shrink-0 text-faint" aria-hidden />
    </button>
  );
}

function Divider() {
  return <div className="mx-4 h-px bg-border/60" aria-hidden />;
}

// Styled "coming soon" view for the Calls tab (no calls backend yet — placeholder by design).
export function CallsComingSoon() {
  return (
    <div className="flex h-full flex-col items-center justify-center gap-3 bg-bg px-8 pb-[calc(84px+env(safe-area-inset-bottom))] text-center">
      <div className="accent-gradient flex h-16 w-16 items-center justify-center rounded-3xl shadow-accent-glow">
        <PhoneIcon />
      </div>
      <h1 className="text-lg font-semibold tracking-[-0.02em] text-fg">Calls are coming soon</h1>
      <p className="max-w-[17rem] text-sm text-muted">
        Voice and video calls aren&apos;t available yet. Keep chatting — we&apos;ll light this tab up
        when they arrive.
      </p>
    </div>
  );
}

function PhoneIcon() {
  // Inline to avoid importing lucide's Phone twice under different names in this file's consumers.
  return (
    <svg
      width="28"
      height="28"
      viewBox="0 0 24 24"
      fill="none"
      stroke="white"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z" />
    </svg>
  );
}
