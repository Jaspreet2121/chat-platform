"use client";

import {
  Heart,
  MessageCircle,
  MessagesSquare,
  Phone,
  UserPlus,
  Users
} from "lucide-react";
import type { Session, UserProfile } from "@/lib/api";
import { Avatar } from "@/components";
import { cn } from "@/lib/cn";

export type MobileView = "chats" | "calls" | "profile";

export type NavRailProps = {
  session: Session | null;
  /** Hide the mobile tab bar (a conversation is open full-screen). Desktop rail is unaffected. */
  mobileHidden?: boolean;
  currentProfile: UserProfile | null;
  /** Any conversation carries unread messages → notification dot on the Messages icon. */
  hasUnread: boolean;
  /** Total unread messages across conversations → count pill on the mobile Messages tab. */
  unreadCount?: number;
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
  activeView = "chats",
  onSelectView,
  onNewGroup,
  onInvite
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
      <button
        type="button"
        onClick={() => onSelectView?.("chats")}
        className={railItemClass(activeView === "chats")}
        aria-current={activeView === "chats" ? "page" : undefined}
        title="Chat"
      >
        <MessageCircle className="h-5 w-5" aria-hidden />
        {hasUnread ? <UnreadDot /> : null}
        <span className="sr-only">Chat</span>
      </button>
      <button
        type="button"
        onClick={() => onSelectView?.("calls")}
        className={railItemClass(activeView === "calls")}
        aria-current={activeView === "calls" ? "page" : undefined}
        title="Call"
      >
        <Phone className="h-5 w-5" aria-hidden />
        <span className="sr-only">Call</span>
      </button>
      {/* Dating (105) — its own top-level route; visible always (routes to setup when off). */}
      <a href="/dating" className={railItemClass(false)} title="Matches">
        <Heart className="h-5 w-5" aria-hidden />
        <span className="sr-only">Matches</span>
      </a>
      <button type="button" onClick={onNewGroup} className={railItemClass(false)} title="New group">
        <Users className="h-5 w-5" aria-hidden />
        <span className="sr-only">New group</span>
      </button>
      <button type="button" onClick={onInvite} className={railItemClass(false)} title="Invite a friend">
        <UserPlus className="h-5 w-5" aria-hidden />
        <span className="sr-only">Invite a friend</span>
      </button>

      <div className="flex-1" aria-hidden />

      {/* Bottom: "You" — the profile avatar opens the Profile screen (which now holds Starred, Appearance,
          Notification sound, Privacy and Log out). This replaces the old standalone Settings icon + menu. */}
      <div className="mb-1 h-px w-8 bg-white/15" aria-hidden />
      {session ? (
        <button
          type="button"
          onClick={() => onSelectView?.("profile")}
          aria-current={activeView === "profile" ? "page" : undefined}
          className={cn(
            "rounded-full outline-none transition-transform hover:scale-105 focus-visible:ring-2 focus-visible:ring-white/60",
            "ring-2 ring-offset-2 ring-offset-transparent",
            activeView === "profile" ? "ring-white/80" : "ring-transparent"
          )}
          title="You"
        >
          <Avatar
            id={session.user_id}
            name={currentProfile?.display_name ?? undefined}
            imageUrl={currentProfile?.avatar_url}
            size="sm"
          />
          <span className="sr-only">You — profile &amp; settings</span>
        </button>
      ) : null}
    </nav>
  );
}

function MobileTabBar({
  session,
  currentProfile,
  hasUnread,
  unreadCount = 0,
  mobileHidden,
  activeView = "chats",
  onSelectView
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
        <span className="relative flex h-6 w-6 items-center justify-center">
          <MessageCircle className="h-5 w-5" aria-hidden />
          {unreadCount > 0 ? (
            <span
              className="accent-gradient absolute -right-2 -top-1.5 flex h-4 min-w-4 items-center justify-center rounded-full px-1 text-[9px] font-semibold leading-none text-white shadow-accent-glow ring-2 ring-white/70 dark:ring-surface/70"
              aria-label={`${unreadCount} unread`}
            >
              {unreadCount > 99 ? "99+" : unreadCount}
            </span>
          ) : hasUnread ? (
            <span className="absolute -right-0.5 -top-0.5 h-2 w-2 rounded-full bg-[#8de08a]" aria-hidden />
          ) : null}
        </span>
        <span className="max-w-full truncate leading-none">Chat</span>
      </button>

      <button
        type="button"
        onClick={() => onSelectView?.("calls")}
        aria-current={activeView === "calls" ? "page" : undefined}
        className={tabClass(activeView === "calls")}
      >
        {activeView === "calls" ? activePill : null}
        <span className="flex h-6 w-6 items-center justify-center">
          <Phone className="h-5 w-5" aria-hidden />
        </span>
        <span className="max-w-full truncate leading-none">Call</span>
      </button>

      <a href="/dating" aria-label="Matches" className={tabClass(false)}>
        <span className="flex h-6 w-6 items-center justify-center">
          <Heart className="h-5 w-5" aria-hidden />
        </span>
        <span className="max-w-full truncate leading-none">Matches</span>
      </a>

      {/* You — WhatsApp-style: profile photo in the same 24px icon slot + a "You" label on the same
          baseline as Chat/Call, so all three tabs share one column structure and vertical
          baseline (no floating-high avatar). The active pill hugs the column. */}
      <button
        type="button"
        onClick={() => onSelectView?.("profile")}
        aria-current={activeView === "profile" ? "page" : undefined}
        aria-label="Your profile"
        className={tabClass(activeView === "profile")}
      >
        {activeView === "profile" ? activePill : null}
        <span className="flex h-6 w-6 items-center justify-center">
          {session ? (
            <Avatar
              id={session.user_id}
              name={currentProfile?.display_name ?? undefined}
              imageUrl={currentProfile?.avatar_url}
              size="sm"
              className={cn(
                "h-5 w-5 text-[8px] ring-2 transition-all",
                activeView === "profile" ? "ring-white/80" : "ring-transparent"
              )}
            />
          ) : (
            <UserPlus className="h-5 w-5" aria-hidden />
          )}
        </span>
        <span className="max-w-full truncate leading-none">You</span>
      </button>
    </nav>
  );
}
