"use client";

import { FormEvent, useEffect, useRef, useState } from "react";
import { UserPlus, X } from "lucide-react";
import { type CountryCode } from "libphonenumber-js";
import { findUserByPhone, type UserProfile } from "@/lib/api";
import { DEFAULT_COUNTRY } from "@/lib/countries";
import { formatSearchInput, toE164Loose } from "@/lib/phone";
import { Avatar, Button, Card, Input } from "@/components";

export type NewConversationModalProps = {
  isOpen: boolean;
  onClose: () => void;

  newTitle: string;
  onNewTitleChange: (value: string) => void;
  onCreateConversation: (event: FormEvent<HTMLFormElement>) => void;
  isCreatingConversation: boolean;

  selectedParticipants: UserProfile[];
  /** Append a phone-resolved participant (deduped by the parent). */
  onAddParticipant: (profile: UserProfile) => void;
  onRemoveParticipant: (userId: string) => void;
};

// Same silent normalization as the chat search (no country dropdown outside login/signup): bare
// national numbers get the default region, "+<cc>…" parses as typed.
const PHONE_ISO = DEFAULT_COUNTRY.iso2 as CountryCode;

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

// "New group" modal (1:1 chats start straight from the sidebar phone search — no type choice here).
// Participants are added by PHONE NUMBER: each number resolves to a platform user via the same
// findUserByPhone lookup the DM search uses, accumulating as removable rows; create submits the
// resolved user IDs (the conversations API is unchanged). Numbers not on the platform get the
// gateway's friendly message + a pointer at the invite flow in the sidebar search.
export function NewConversationModal({
  isOpen,
  onClose,
  newTitle,
  onNewTitleChange,
  onCreateConversation,
  isCreatingConversation,
  selectedParticipants,
  onAddParticipant,
  onRemoveParticipant
}: NewConversationModalProps) {
  const wasCreatingRef = useRef(false);

  // Phone → participant lookup. The raw input formats as-you-type; `phoneDestination` is the silently
  // normalized E.164 ("" while incomplete/invalid) — same helpers as the chat search.
  const [phoneRaw, setPhoneRaw] = useState("");
  const [isFinding, setIsFinding] = useState(false);
  const [findError, setFindError] = useState("");
  const phoneDestination = toE164Loose(phoneRaw, PHONE_ISO);

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

  async function handleAddByPhone() {
    const phone = phoneDestination.trim();
    if (!phone) {
      setFindError("Enter a complete phone number first.");
      return;
    }
    setIsFinding(true);
    setFindError("");
    try {
      const profile = await findUserByPhone(phone);
      onAddParticipant(profile);
      setPhoneRaw("");
    } catch (error) {
      const message = error instanceof Error ? error.message : "Could not find that number.";
      setFindError(
        /no account/i.test(message)
          ? "This number isn't on Growblic yet — invite them from the chat search first."
          : message
      );
    } finally {
      setIsFinding(false);
    }
  }

  function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    // With a pending (typed but un-added) number, Enter adds it; otherwise it creates the group.
    if (phoneDestination.trim()) {
      void handleAddByPhone();
    } else {
      onCreateConversation(event);
    }
  }

  const canCreate = selectedParticipants.length > 0 && newTitle.trim().length > 0;

  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm animate-fade-in">
      <button type="button" aria-label="Close" onClick={onClose} className="absolute inset-0" />

      <Card className="relative flex max-h-[min(80dvh,34rem)] w-[calc(100%-2rem)] max-w-sm flex-col p-0 animate-scale-in">
        <header className="flex items-center justify-between border-b border-border px-4 py-3">
          <h2 className="text-sm font-semibold text-fg">New group</h2>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close"
            className="rounded-lg p-1.5 text-muted transition-colors hover:bg-elevated hover:text-fg"
          >
            <X className="h-4 w-4" aria-hidden />
          </button>
        </header>

        <form className="flex-1 space-y-3 overflow-y-auto p-4" onSubmit={handleSubmit}>
          <Input
            label="Group title"
            placeholder="e.g. Launch Team"
            value={newTitle}
            onChange={(event) => onNewTitleChange(event.target.value)}
            autoFocus
          />

          {/* Add participants by phone number (same lookup as the DM search). */}
          <div className="space-y-2 rounded-xl border border-border bg-elevated p-2.5">
            <Input
              label="Participant's phone number"
              inputMode="tel"
              autoComplete="off"
              placeholder="Type their number"
              value={phoneRaw}
              onChange={(event) => setPhoneRaw(formatSearchInput(event.target.value, PHONE_ISO))}
              className="bg-surface"
            />
            <Button
              type="button"
              variant="ghost"
              fullWidth
              onClick={() => void handleAddByPhone()}
              isLoading={isFinding}
              disabled={phoneDestination.trim() === "" || isFinding}
              leftIcon={<UserPlus className="h-4 w-4" aria-hidden />}
              className="border border-border"
            >
              Add participant
            </Button>
            {findError ? <p className="text-xs text-danger">{findError}</p> : null}
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

          <p className="px-0.5 text-xs text-faint">
            Add a title and the phone numbers of the people to include.
          </p>

          <Button type="submit" fullWidth isLoading={isCreatingConversation} disabled={!canCreate && !phoneDestination.trim()}>
            {phoneDestination.trim() ? "Add participant" : "Create group"}
          </Button>
        </form>
      </Card>
    </div>
  );
}
