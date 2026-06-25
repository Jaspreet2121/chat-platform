"use client";

import { FormEvent, useEffect, useRef } from "react";
import { Search, User, UserPlus, Users, X } from "lucide-react";
import type { UserProfile } from "@/lib/api";
import { Avatar, Button, Card, Input } from "@/components";
import { cn } from "@/lib/cn";

type ConversationMode = "direct" | "group";

export type NewConversationModalProps = {
  isOpen: boolean;
  onClose: () => void;

  // The exact same new-conversation state + handlers the sidebar used inline — just relocated here.
  newTitle: string;
  onNewTitleChange: (value: string) => void;
  /** "direct" = 1:1 (one participant, no title); "group" = titled multi-party. */
  mode: ConversationMode;
  onModeChange: (mode: ConversationMode) => void;
  onCreateConversation: (event: FormEvent<HTMLFormElement>) => void;
  isCreatingConversation: boolean;
  lookupUserId: string;
  onLookupUserIdChange: (value: string) => void;
  onLookup: () => void;
  isLookingUpProfile: boolean;
  lookupStatus: string;
  lookupProfile: UserProfile | null;
  onAddParticipant: () => void;
  selectedParticipants: UserProfile[];
  onRemoveParticipant: (userId: string) => void;
};

const MODES: { key: ConversationMode; label: string; icon: typeof User }[] = [
  { key: "direct", label: "Direct message", icon: User },
  { key: "group", label: "Group", icon: Users }
];

function shortId(id: string): string {
  return `#${id.slice(0, 8)}`;
}

function ProfileSummary({ profile }: { profile: UserProfile }) {
  return (
    <div className="flex min-w-0 items-center gap-2">
      <Avatar
        id={profile.user_id}
        name={profile.display_name ?? undefined}
        imageUrl={profile.avatar_url}
        size="sm"
      />
      <div className="min-w-0">
        <p className="truncate text-sm font-medium text-fg">
          {profile.display_name || "Unnamed profile"}
        </p>
        <p className="truncate text-xs text-faint">{shortId(profile.user_id)}</p>
      </div>
    </div>
  );
}

// "New conversation" modal with an explicit Direct vs Group choice:
//  - Direct → pick ONE participant, no title → a 1:1 (type:"direct"). The lookup hides once one
//    person is chosen (remove to swap), so a direct chat is always exactly two people.
//  - Group → a title + one or more participants (type:"group").
// State + handlers still come from the page (passed through); this just shapes the form per mode and
// self-closes on success (the page clears selectedParticipants only on a successful create).
export function NewConversationModal({
  isOpen,
  onClose,
  newTitle,
  onNewTitleChange,
  mode,
  onModeChange,
  onCreateConversation,
  isCreatingConversation,
  lookupUserId,
  onLookupUserIdChange,
  onLookup,
  isLookingUpProfile,
  lookupStatus,
  lookupProfile,
  onAddParticipant,
  selectedParticipants,
  onRemoveParticipant
}: NewConversationModalProps) {
  const wasCreatingRef = useRef(false);

  useEffect(() => {
    if (!isOpen) return;
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape") onClose();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [isOpen, onClose]);

  // Success = a create finished (isCreatingConversation true → false) AND the page cleared the
  // participants (it only clears them on success). Failure leaves them, so the modal stays open.
  useEffect(() => {
    if (!isOpen) return;
    if (wasCreatingRef.current && !isCreatingConversation && selectedParticipants.length === 0) {
      onClose();
    }
    wasCreatingRef.current = isCreatingConversation;
  }, [isOpen, isCreatingConversation, selectedParticipants.length, onClose]);

  if (!isOpen) return null;

  const isDirect = mode === "direct";
  // Direct chats are exactly two people: only offer the lookup until one peer is chosen.
  const showLookup = !isDirect || selectedParticipants.length === 0;
  const canCreate = isDirect
    ? selectedParticipants.length === 1
    : selectedParticipants.length > 0 && newTitle.trim().length > 0;

  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm animate-fade-in">
      <button type="button" aria-label="Close" onClick={onClose} className="absolute inset-0" />

      <Card className="relative flex max-h-[85vh] w-full max-w-sm flex-col p-0 animate-scale-in">
        <header className="flex items-center justify-between border-b border-border px-4 py-3">
          <h2 className="text-sm font-semibold text-fg">New conversation</h2>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close"
            className="rounded-lg p-1.5 text-muted transition-colors hover:bg-elevated hover:text-fg"
          >
            <X className="h-4 w-4" aria-hidden />
          </button>
        </header>

        <form className="flex-1 space-y-3 overflow-y-auto p-4" onSubmit={onCreateConversation}>
          {/* Direct vs Group — the explicit choice that decides type:"direct" vs type:"group". */}
          <div role="tablist" aria-label="Conversation type" className="flex gap-1 rounded-xl border border-border bg-elevated p-1">
            {MODES.map((option) => {
              const Icon = option.icon;
              const active = mode === option.key;
              return (
                <button
                  key={option.key}
                  type="button"
                  role="tab"
                  aria-selected={active}
                  onClick={() => onModeChange(option.key)}
                  className={cn(
                    "flex flex-1 items-center justify-center gap-1.5 rounded-lg px-2 py-1.5 text-xs font-medium transition-all duration-150",
                    "outline-none focus-visible:ring-2 focus-visible:ring-brand-ring",
                    active
                      ? "bg-brand-subtle text-brand-hover shadow-subtle ring-1 ring-inset ring-brand/20"
                      : "text-muted hover:text-fg"
                  )}
                >
                  <Icon className="h-3.5 w-3.5" aria-hidden />
                  {option.label}
                </button>
              );
            })}
          </div>

          {/* Title — groups only (a direct chat is named after the other person). */}
          {!isDirect ? (
            <Input
              label="Group title"
              placeholder="e.g. Launch Team"
              value={newTitle}
              onChange={(event) => onNewTitleChange(event.target.value)}
              autoFocus
            />
          ) : null}

          {showLookup ? (
            <div className="space-y-2 rounded-xl border border-border bg-elevated p-2.5">
              <div className="flex gap-2">
                <Input
                  leftIcon={<Search className="h-4 w-4" aria-hidden />}
                  placeholder={isDirect ? "Find a person by user ID" : "Participant user ID"}
                  value={lookupUserId}
                  onChange={(event) => onLookupUserIdChange(event.target.value)}
                  className="bg-surface"
                />
                <Button
                  type="button"
                  variant="ghost"
                  onClick={onLookup}
                  isLoading={isLookingUpProfile}
                  className="shrink-0 border border-border"
                >
                  Lookup
                </Button>
              </div>

              {lookupStatus ? <p className="text-xs text-muted">{lookupStatus}</p> : null}

              {lookupProfile ? (
                <div className="flex items-center justify-between gap-2 rounded-lg bg-surface p-2">
                  <ProfileSummary profile={lookupProfile} />
                  <Button
                    type="button"
                    size="sm"
                    onClick={onAddParticipant}
                    leftIcon={<UserPlus className="h-4 w-4" aria-hidden />}
                  >
                    Add
                  </Button>
                </div>
              ) : null}
            </div>
          ) : null}

          {selectedParticipants.length > 0 ? (
            <div className="space-y-2">
              {selectedParticipants.map((participant) => (
                <div
                  key={participant.user_id}
                  className="flex items-center justify-between gap-2 rounded-lg border border-border bg-elevated p-2"
                >
                  <ProfileSummary profile={participant} />
                  <button
                    type="button"
                    onClick={() => onRemoveParticipant(participant.user_id)}
                    className="shrink-0 rounded-md p-1 text-faint transition-colors hover:text-danger"
                    aria-label="Remove participant"
                  >
                    <X className="h-4 w-4" aria-hidden />
                  </button>
                </div>
              ))}
            </div>
          ) : null}

          <p className="px-0.5 text-xs text-faint">
            {isDirect
              ? selectedParticipants.length === 0
                ? "Pick one person for a private 1:1 chat."
                : "Direct 1:1 chat — named after the other person."
              : "Add a title and one or more people for a group chat."}
          </p>

          <Button type="submit" fullWidth isLoading={isCreatingConversation} disabled={!canCreate}>
            {isDirect ? "Start direct chat" : "Create group"}
          </Button>
        </form>
      </Card>
    </div>
  );
}
