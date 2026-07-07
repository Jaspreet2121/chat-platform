"use client";

import { useEffect, useMemo, useState } from "react";
import { Loader2, Search, UserPlus, Users, X } from "lucide-react";
import { type CountryCode } from "libphonenumber-js";
import { DEFAULT_COUNTRY } from "@/lib/countries";
import { formatSearchInput, toE164Loose } from "@/lib/phone";
import { findUserByPhone, getConversation, type UserProfile } from "@/lib/api";
import { Avatar, Button } from "@/components";
import { cn } from "@/lib/cn";
import { useUserProfile } from "../chat/useUserProfile";

/** Who to add: an existing member (userId) or an outside person (phone). `label` is only for the toast. */
export type AddTarget = { userId?: string; phone?: string; label?: string };

export type AddParticipantsSheetProps = {
  /** The group call's conversation — its member list is fetched on open. Absent for a 1-on-1 being promoted
   *  (a DM's only other member is already in the call) → the sheet opens on the "by number" tab. */
  conversationId?: string | null;
  /** LiveKit identities already in the call (self + remotes) — excluded from the member list. */
  inCallIds: string[];
  currentUserId?: string;
  /** Ring the target into the call (fire-and-forget; feedback comes back as a toast). */
  onAdd: (target: AddTarget) => void;
  onClose: () => void;
};

const DEBOUNCE_MS = 350;
const SEARCH_ISO = DEFAULT_COUNTRY.iso2 as CountryCode;

type Tab = "members" | "number";

type PhoneLookup =
  | { kind: "idle" }
  | { kind: "loading" }
  | { kind: "found"; profile: UserProfile }
  | { kind: "empty" }
  | { kind: "self" }
  | { kind: "error"; message: string };

/** One selectable member row — resolves its own display name/avatar (same hook the chat rows use). */
function MemberRow({ userId, onAdd }: { userId: string; onAdd: () => void }) {
  const profile = useUserProfile(userId);
  const name = profile?.display_name?.trim() || `${userId.slice(0, 8)}…`;

  return (
    <button
      type="button"
      onClick={onAdd}
      className="flex w-full items-center gap-3 rounded-xl px-2 py-2 text-left transition-colors hover:bg-elevated"
    >
      <Avatar id={userId} name={name} imageUrl={profile?.avatar_url} size="sm" />
      <span className="min-w-0 flex-1 truncate text-sm text-fg">{name}</span>
      <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-brand-subtle text-brand-hover">
        <UserPlus className="h-4 w-4" aria-hidden />
      </span>
    </button>
  );
}

/**
 * In-call "Add participants" sheet. Two ways to add someone to a LIVE group call: pick a conversation
 * member who isn't already in the call, or look someone up by phone number. Either taps `onAdd`, which
 * rings them via the backend (call:group_add) — the sheet just closes; the ring/feedback is a toast.
 */
export function AddParticipantsSheet({
  conversationId,
  inCallIds,
  currentUserId,
  onAdd,
  onClose
}: AddParticipantsSheetProps) {
  // No conversation (1-on-1 promote) → start on the number tab; the member list is empty by construction.
  const [tab, setTab] = useState<Tab>(conversationId ? "members" : "number");

  // Member list — fetched once on open (CallProvider doesn't hold it): all active members except me. Who's
  // already in the call is filtered out reactively below, so a mid-open join updates the list without refetch.
  // With no conversationId there are no members to list (a DM's other party is already in the call) → [].
  const [allMemberIds, setAllMemberIds] = useState<string[] | null>(conversationId ? null : []);
  const [membersError, setMembersError] = useState(false);

  useEffect(() => {
    if (!conversationId) return;
    let active = true;
    getConversation(conversationId)
      .then((detail) => {
        if (!active) return;
        const ids = (detail.participants ?? [])
          .filter((p) => !p.left_at && p.user_id !== currentUserId)
          .map((p) => p.user_id);
        setAllMemberIds(ids);
      })
      .catch(() => {
        if (active) setMembersError(true);
      });
    return () => {
      active = false;
    };
  }, [conversationId, currentUserId]);

  const inCallSet = useMemo(() => new Set(inCallIds), [inCallIds]);
  const memberIds = useMemo(
    () => (allMemberIds === null ? null : allMemberIds.filter((id) => !inCallSet.has(id))),
    [allMemberIds, inCallSet]
  );

  function handleAddMember(userId: string, label: string) {
    onAdd({ userId, label });
    onClose();
  }

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Add participants"
      className="fixed inset-0 z-[70] flex items-end justify-center sm:items-center"
    >
      <button
        type="button"
        aria-label="Close"
        onClick={onClose}
        className="absolute inset-0 bg-black/50 backdrop-blur-sm animate-fade-in"
      />

      <div className="relative flex max-h-[80vh] w-full flex-col rounded-t-2xl border border-border bg-surface shadow-xl animate-slide-up sm:m-4 sm:max-w-md sm:rounded-2xl">
        {/* Header */}
        <div className="flex items-center gap-3 border-b border-border px-4 py-3">
          <UserPlus className="h-5 w-5 shrink-0 text-brand-hover" aria-hidden />
          <h2 className="min-w-0 flex-1 text-sm font-semibold text-fg">Add to call</h2>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close"
            className="rounded-md p-1 text-faint transition-colors hover:text-fg"
          >
            <X className="h-5 w-5" aria-hidden />
          </button>
        </div>

        {/* Tabs */}
        <div className="flex gap-1 px-3 pt-3">
          <TabButton active={tab === "members"} onClick={() => setTab("members")}>
            <Users className="h-4 w-4" aria-hidden /> Group members
          </TabButton>
          <TabButton active={tab === "number"} onClick={() => setTab("number")}>
            <Search className="h-4 w-4" aria-hidden /> By number
          </TabButton>
        </div>

        {/* Content */}
        <div className="min-h-0 flex-1 overflow-y-auto px-3 py-3">
          {tab === "members" ? (
            <MembersTab
              memberIds={memberIds}
              error={membersError}
              onAdd={handleAddMember}
            />
          ) : (
            <NumberTab
              currentUserId={currentUserId}
              onAdd={(target) => {
                onAdd(target);
                onClose();
              }}
            />
          )}
        </div>
      </div>
    </div>
  );
}

function TabButton({
  active,
  onClick,
  children
}: {
  active: boolean;
  onClick: () => void;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "flex flex-1 items-center justify-center gap-1.5 rounded-lg px-3 py-2 text-xs font-medium transition-colors",
        active ? "bg-brand-subtle text-brand-hover" : "text-muted hover:bg-elevated hover:text-fg"
      )}
    >
      {children}
    </button>
  );
}

function MembersTab({
  memberIds,
  error,
  onAdd
}: {
  memberIds: string[] | null;
  error: boolean;
  onAdd: (userId: string, label: string) => void;
}) {
  if (error) {
    return <p className="px-2 py-6 text-center text-sm text-muted">Couldn&apos;t load members.</p>;
  }
  if (memberIds === null) {
    return (
      <div className="flex items-center justify-center py-8">
        <Loader2 className="h-5 w-5 animate-spin text-brand-hover" aria-hidden />
      </div>
    );
  }
  if (memberIds.length === 0) {
    return (
      <p className="px-2 py-6 text-center text-sm text-muted">Everyone&apos;s already in the call.</p>
    );
  }
  return (
    <div className="flex flex-col gap-0.5">
      {memberIds.map((id) => (
        <MemberRowResolved key={id} userId={id} onAdd={onAdd} />
      ))}
    </div>
  );
}

// Wraps MemberRow so the resolved display name is what we pass up as the toast label.
function MemberRowResolved({
  userId,
  onAdd
}: {
  userId: string;
  onAdd: (userId: string, label: string) => void;
}) {
  const profile = useUserProfile(userId);
  const label = profile?.display_name?.trim() || "them";
  return <MemberRow userId={userId} onAdd={() => onAdd(userId, label)} />;
}

function NumberTab({
  currentUserId,
  onAdd
}: {
  currentUserId?: string;
  onAdd: (target: AddTarget) => void;
}) {
  const [localNumber, setLocalNumber] = useState("");
  const [state, setState] = useState<PhoneLookup>({ kind: "idle" });

  const e164 = useMemo(() => toE164Loose(localNumber, SEARCH_ISO), [localNumber]);
  const hasDigits = localNumber.replace(/\D/g, "").length > 0;

  useEffect(() => {
    let cancelled = false;
    if (!e164) {
      const reset = setTimeout(() => {
        if (!cancelled) setState({ kind: "idle" });
      }, 0);
      return () => {
        cancelled = true;
        clearTimeout(reset);
      };
    }
    const handle = setTimeout(() => {
      setState({ kind: "loading" });
      findUserByPhone(e164)
        .then((profile) => {
          if (cancelled) return;
          if (profile.user_id === currentUserId) setState({ kind: "self" });
          else setState({ kind: "found", profile });
        })
        .catch((error) => {
          if (cancelled) return;
          const message = error instanceof Error ? error.message : "Lookup failed.";
          if (/no account/i.test(message)) setState({ kind: "empty" });
          else if (/yourself/i.test(message)) setState({ kind: "self" });
          else setState({ kind: "error", message });
        });
    }, DEBOUNCE_MS);
    return () => {
      cancelled = true;
      clearTimeout(handle);
    };
  }, [e164, currentUserId]);

  return (
    <div>
      <div className="relative">
        <Search
          className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-faint"
          aria-hidden
        />
        <input
          inputMode="tel"
          autoComplete="off"
          placeholder="Add by phone number"
          value={localNumber}
          onChange={(e) => setLocalNumber(formatSearchInput(e.target.value, SEARCH_ISO))}
          aria-label="Add by phone number"
          className={cn(
            "h-11 w-full rounded-xl border border-border/70 bg-elevated/50 pl-9 pr-9 text-sm text-fg",
            "placeholder:text-faint outline-none transition-colors duration-150",
            "focus:border-brand/50 focus:bg-elevated focus:ring-1 focus:ring-brand-ring"
          )}
        />
        {state.kind === "loading" ? (
          <Loader2
            className="absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 animate-spin text-brand-hover"
            aria-hidden
          />
        ) : hasDigits ? (
          <button
            type="button"
            onClick={() => setLocalNumber("")}
            aria-label="Clear"
            className="absolute right-2 top-1/2 -translate-y-1/2 rounded-md p-1 text-faint transition-colors hover:text-fg"
          >
            <X className="h-4 w-4" aria-hidden />
          </button>
        ) : null}
      </div>

      {state.kind === "found" ? (
        <div className="mt-2 flex items-center gap-2.5 rounded-xl border border-border/60 bg-elevated/50 p-2 animate-fade-in">
          <Avatar
            id={state.profile.user_id}
            name={state.profile.display_name ?? undefined}
            imageUrl={state.profile.avatar_url}
            size="sm"
          />
          <div className="min-w-0 flex-1">
            <p className="truncate text-sm text-fg">
              {state.profile.display_name || "Unnamed profile"}
            </p>
            <p className="truncate text-xs text-faint">#{state.profile.user_id.slice(0, 8)}</p>
          </div>
          <Button
            size="sm"
            onClick={() =>
              onAdd({ phone: e164, label: state.profile.display_name?.trim() || "them" })
            }
            leftIcon={<UserPlus className="h-4 w-4" aria-hidden />}
            className="shrink-0"
          >
            Add
          </Button>
        </div>
      ) : state.kind === "empty" ? (
        <p className="mt-2 px-1 text-xs text-muted animate-fade-in">No user with that number.</p>
      ) : state.kind === "self" ? (
        <p className="mt-2 px-1 text-xs text-muted animate-fade-in">That&apos;s your own number.</p>
      ) : state.kind === "error" ? (
        <p className="mt-2 px-1 text-xs text-danger animate-fade-in">{state.message}</p>
      ) : null}
    </div>
  );
}
