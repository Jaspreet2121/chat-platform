"use client";

import { FormEvent, useEffect, useRef } from "react";
import { Search, UserPlus, X } from "lucide-react";
import type { UserProfile } from "@/lib/api";
import { Avatar, Button, Card, Input } from "@/components";

export type NewConversationModalProps = {
  isOpen: boolean;
  onClose: () => void;

  // The exact same new-conversation state + handlers the sidebar used inline — just relocated here.
  newTitle: string;
  onNewTitleChange: (value: string) => void;
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

// "New conversation" modal — the create/lookup form relocated from the sidebar body, with the SAME
// state + handlers (passed through). The create flow is unchanged; this just self-closes on success
// (the page clears selectedParticipants on a successful create) while keeping the Create button's
// loading state visible during the request. On failure the modal stays open (error shows in the banner).
export function NewConversationModal({
  isOpen,
  onClose,
  newTitle,
  onNewTitleChange,
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
          <Input
            label="Conversation title"
            placeholder="e.g. Launch Team"
            value={newTitle}
            onChange={(event) => onNewTitleChange(event.target.value)}
            autoFocus
          />

          <div className="space-y-2 rounded-xl border border-border bg-elevated p-2.5">
            <div className="flex gap-2">
              <Input
                leftIcon={<Search className="h-4 w-4" aria-hidden />}
                placeholder="Participant user ID"
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

          <Button
            type="submit"
            fullWidth
            isLoading={isCreatingConversation}
            disabled={selectedParticipants.length === 0}
          >
            Create conversation
          </Button>
        </form>
      </Card>
    </div>
  );
}
