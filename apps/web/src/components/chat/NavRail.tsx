"use client";

import { useEffect, useRef, useState } from "react";
import {
  LogOut,
  MessageCircle,
  MessagesSquare,
  Phone,
  Settings,
  Star,
  UserPlus,
  Users
} from "lucide-react";
import type { Session, UserProfile } from "@/lib/api";
import { Avatar, ThemeToggle } from "@/components";
import { cn } from "@/lib/cn";

export type MobileView = "chats" | "calls" | "profile";

export type NavRailProps = {
  session: Session | null;
  /** Hide the mobile tab bar (a conversation is open full-screen). Desktop rail is unaffected. */
  mobileHidden?: boolean;
  currentProfile: UserProfile | null;
  /** Any conversation carries unread messages → notification dot on the Messages icon. */
  hasUnread: boolean;
  /** The mobile screen currently shown (Messages / Calls-placeholder / Profile). */
  activeView?: MobileView;
  /** Switch the mobile screen (view tabs: Messages, Calls, You). */
  onSelectView?: (view: MobileView) => void;
  /** Groups → open the new-conversation modal in group mode. */
  onNewGroup: () => void;
  /** Invite → focus the phone-number search (its empty state offers the WhatsApp/SMS invite). */
  onInvite: () => void;
  onOpenStarred: () => void;
  onOpenProfile: () => void;
  onLogout: () => void;
};

/**
 * App navigation, one component, two shapes:
 *  - ≥md: the thin 60px indigo-gradient LEFT RAIL (logo · messages/calls/groups/invite · settings ·
 *    profile) from the approved mockup.
 *  - <md: a bottom TAB BAR with the same destinations (chosen over a slide-in menu so primary nav
 *    stays one thumb-tap away and nothing hides behind a hamburger).
 * Settings opens a small menu (theme · starred · log out) — those actions moved here from the old
 * sidebar header, which keeps the chat list header clean like the mock.
 */
export function NavRail(props: NavRailProps) {
  return (
    <>
      <DesktopRail {...props} />
      <MobileTabBar {...props} />
    </>
  );
}

function railItemClass(active: boolean): string {
  return cn(
    "relative flex h-11 w-11 items-center justify-center rounded-xl transition-colors duration-150",
    "outline-none focus-visible:ring-2 focus-visible:ring-white/60",
    active ? "bg-white/20 text-white" : "text-white/65 hover:bg-white/10 hover:text-white"
  );
}

function UnreadDot() {
  return (
    <span
      className="absolute right-2 top-2 h-2 w-2 rounded-full bg-[#8de08a] ring-2 ring-[#4e4e82]"
      aria-hidden
    />
  );
}

function DesktopRail({
  session,
  currentProfile,
  hasUnread,
  onNewGroup,
  onInvite,
  onOpenStarred,
  onOpenProfile,
  onLogout
}: NavRailProps) {
  return (
    <nav
      aria-label="Main navigation"
      className="rail-gradient hidden w-[60px] shrink-0 flex-col items-center gap-1 py-3 md:flex"
    >
      {/* Brand tile */}
      <div
        className="accent-gradient mb-1 flex h-10 w-10 items-center justify-center rounded-xl shadow-accent-glow"
        aria-hidden
      >
        <MessagesSquare className="h-5 w-5 text-white" />
      </div>
      <div className="mb-1 h-px w-8 bg-white/15" aria-hidden />

      {/* Primary destinations, grouped near the top */}
      <span className={railItemClass(true)} aria-current="page" title="Messages">
        <MessageCircle className="h-5 w-5" aria-hidden />
        {hasUnread ? <UnreadDot /> : null}
        <span className="sr-only">Messages</span>
      </span>
      <button
        type="button"
        className={cn(railItemClass(false), "cursor-not-allowed opacity-50")}
        title="Calls — coming soon"
        aria-disabled="true"
      >
        <Phone className="h-5 w-5" aria-hidden />
        <span className="sr-only">Calls (coming soon)</span>
      </button>
      <button type="button" onClick={onNewGroup} className={railItemClass(false)} title="New group">
        <Users className="h-5 w-5" aria-hidden />
        <span className="sr-only">New group</span>
      </button>
      <button type="button" onClick={onInvite} className={railItemClass(false)} title="Invite a friend">
        <UserPlus className="h-5 w-5" aria-hidden />
        <span className="sr-only">Invite a friend</span>
      </button>

      <div className="flex-1" aria-hidden />

      {/* Bottom: settings menu · divider · profile */}
      <SettingsMenu onOpenStarred={onOpenStarred} onLogout={onLogout} direction="up" />
      <div className="my-1 h-px w-8 bg-white/15" aria-hidden />
      {session ? (
        <button
          type="button"
          onClick={onOpenProfile}
          className="rounded-full outline-none transition-transform hover:scale-105 focus-visible:ring-2 focus-visible:ring-white/60"
          title="My profile"
        >
          <Avatar
            id={session.user_id}
            name={currentProfile?.display_name ?? undefined}
            imageUrl={currentProfile?.avatar_url}
            size="sm"
          />
          <span className="sr-only">My profile</span>
        </button>
      ) : null}
    </nav>
  );
}

function MobileTabBar({
  session,
  currentProfile,
  hasUnread,
  mobileHidden,
  activeView = "chats",
  onSelectView,
  onNewGroup,
  onInvite
}: NavRailProps) {
  if (mobileHidden) return null;

  // Liquid-glass floating pill: translucent frosted surface over the periwinkle page, active tab
  // carried on an accent-gradient pill. All five tabs flex evenly (basis-0 min-w-0) so 360px fits.
  const tabClass = (active: boolean) =>
    cn(
      "relative flex h-full min-w-0 flex-1 basis-0 flex-col items-center justify-center gap-0.5 rounded-2xl text-[10px] font-medium",
      "outline-none transition-all duration-200 ease-out-soft focus-visible:ring-2 focus-visible:ring-brand-ring",
      active ? "text-white" : "text-muted hover:text-fg active:scale-95"
    );

  const activePill = (
    <span
      className="accent-gradient absolute inset-x-1 inset-y-1 -z-10 rounded-2xl shadow-accent-glow animate-scale-in"
      aria-hidden
    />
  );

  return (
    <nav
      aria-label="Main navigation"
      className={cn(
        "fixed inset-x-3 z-40 flex h-[64px] items-stretch gap-0.5 rounded-[26px] px-1.5 py-1 md:hidden",
        "bottom-[max(0.75rem,env(safe-area-inset-bottom))]",
        // Frosted glass: translucent surface + blur + hairline border + soft lifted shadow.
        "border border-white/50 bg-white/70 shadow-elevated backdrop-blur-xl backdrop-saturate-150",
        "dark:border-white/10 dark:bg-surface/70"
      )}
    >
      <button
        type="button"
        onClick={() => onSelectView?.("chats")}
        aria-current={activeView === "chats" ? "page" : undefined}
        className={tabClass(activeView === "chats")}
      >
        {activeView === "chats" ? activePill : null}
        <span className="relative">
          <MessageCircle className="h-5 w-5" aria-hidden />
          {hasUnread ? (
            <span className="absolute -right-1 -top-1 h-2 w-2 rounded-full bg-[#8de08a]" aria-hidden />
          ) : null}
        </span>
        <span className="max-w-full truncate">Messages</span>
      </button>

      <button type="button" onClick={onNewGroup} className={tabClass(false)}>
        <Users className="h-5 w-5" aria-hidden />
        <span className="max-w-full truncate">Groups</span>
      </button>

      <button
        type="button"
        onClick={() => onSelectView?.("calls")}
        aria-current={activeView === "calls" ? "page" : undefined}
        className={tabClass(activeView === "calls")}
      >
        {activeView === "calls" ? activePill : null}
        <Phone className="h-5 w-5" aria-hidden />
        <span className="max-w-full truncate">Calls</span>
      </button>

      <button type="button" onClick={onInvite} className={tabClass(false)}>
        <UserPlus className="h-5 w-5" aria-hidden />
        <span className="max-w-full truncate">Invite</span>
      </button>

      <button
        type="button"
        onClick={() => onSelectView?.("profile")}
        aria-current={activeView === "profile" ? "page" : undefined}
        className={tabClass(activeView === "profile")}
      >
        {activeView === "profile" ? activePill : null}
        {session ? (
          <Avatar
            id={session.user_id}
            name={currentProfile?.display_name ?? undefined}
            imageUrl={currentProfile?.avatar_url}
            size="sm"
            className="h-6 w-6 text-[9px]"
          />
        ) : (
          <UserPlus className="h-5 w-5" aria-hidden />
        )}
        <span className="max-w-full truncate">You</span>
      </button>
    </nav>
  );
}

// Small anchored menu for the secondary actions (theme toggle · starred · log out).
function SettingsMenu({
  onOpenStarred,
  onLogout,
  direction,
  bare
}: {
  onOpenStarred: () => void;
  onLogout: () => void;
  direction: "up" | "down";
  bare?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    function onDown(event: MouseEvent | TouchEvent) {
      if (ref.current && !ref.current.contains(event.target as Node)) setOpen(false);
    }
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape") setOpen(false);
    }
    document.addEventListener("mousedown", onDown);
    document.addEventListener("touchstart", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("touchstart", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  return (
    <div ref={ref} className="relative flex flex-col items-center">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
        aria-haspopup="menu"
        className={
          bare
            ? "flex flex-col items-center gap-0.5 outline-none focus-visible:ring-2 focus-visible:ring-white/60"
            : railItemClass(open)
        }
      >
        <Settings className="h-5 w-5" aria-hidden />
        {bare ? <span className="max-w-full truncate">Settings</span> : <span className="sr-only">Settings</span>}
      </button>

      {open ? (
        <div
          role="menu"
          className={cn(
            "absolute z-40 w-44 overflow-hidden rounded-xl border border-border bg-surface p-1 shadow-elevated animate-scale-in",
            direction === "up" ? "bottom-full mb-2" : "top-full mt-2",
            "left-1/2 -translate-x-1/2 sm:left-full sm:ml-2 sm:translate-x-0 md:bottom-0 md:left-full md:mb-0"
          )}
        >
          <div className="flex items-center justify-between rounded-lg px-3 py-2 text-sm text-fg">
            Theme
            <ThemeToggle />
          </div>
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              setOpen(false);
              onOpenStarred();
            }}
            className="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left text-sm text-fg transition-colors hover:bg-elevated"
          >
            <Star className="h-4 w-4 text-muted" aria-hidden />
            Starred messages
          </button>
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              setOpen(false);
              onLogout();
            }}
            className="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left text-sm text-danger transition-colors hover:bg-danger/10"
          >
            <LogOut className="h-4 w-4" aria-hidden />
            Log out
          </button>
        </div>
      ) : null}
    </div>
  );
}
