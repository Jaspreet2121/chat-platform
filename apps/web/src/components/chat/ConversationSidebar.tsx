import { FormEvent, useState } from "react";
import { LogOut, MessagesSquare, Plus, Search, Star, UserPlus, X } from "lucide-react";
import type {
  ConversationListItem as ConversationListItemData,
  Session,
  UserProfile
} from "@/lib/api";
import { Avatar, Button, IconButton, Input, ThemeToggle } from "@/components";
import { cn } from "@/lib/cn";
import { ConversationListItem } from "./ConversationListItem";
import { EmptyState } from "./EmptyState";
import { MessageSearch } from "./MessageSearch";

type ConversationFilter = "all" | "personal" | "groups";

const FILTERS: { key: ConversationFilter; label: string }[] = [
  { key: "all", label: "All" },
  { key: "personal", label: "Personal" },
  { key: "groups", label: "Groups" }
];

export type ConversationSidebarProps = {
  session: Session | null;
  currentProfile: UserProfile | null;
  onLogout: () => void;
  /** Open the Starred messages panel. */
  onOpenStarred: () => void;
  /** Open the "My Profile" editor (from the signed-in identity). */
  onOpenProfile: () => void;

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

  conversations: ConversationListItemData[];
  selectedConversationId: string;
  onSelectConversation: (conversationId: string) => void;
  /** Open a conversation AND scroll to a specific message (used by search results). */
  onJumpToMessage: (conversationId: string, messageId: string) => void;
  isLoading: boolean;
};

function shortId(id: string): string {
  return `#${id.slice(0, 8)}`;
}

function ProfileSummary({ profile }: { profile: UserProfile }) {
  return (
    <div className="flex min-w-0 items-center gap-2">
      <Avatar id={profile.user_id} name={profile.display_name ?? undefined} size="sm" />
      <div className="min-w-0">
        <p className="truncate text-sm font-medium text-fg">
          {profile.display_name || "Unnamed profile"}
        </p>
        <p className="truncate text-xs text-faint">{shortId(profile.user_id)}</p>
      </div>
    </div>
  );
}

export function ConversationSidebar(props: ConversationSidebarProps) {
  const {
    session,
    currentProfile,
    onLogout,
    onOpenStarred,
    onOpenProfile,
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
    onRemoveParticipant,
    conversations,
    selectedConversationId,
    onSelectConversation,
    onJumpToMessage,
    isLoading
  } = props;

  // Client-side filter by conversation type (purely a UI view of the existing list — no fetch/handler).
  const [filter, setFilter] = useState<ConversationFilter>("all");
  const filteredConversations = conversations.filter((conversation) => {
    if (filter === "personal") return conversation.type === "direct";
    if (filter === "groups") return conversation.type !== "direct";
    return true;
  });

  return (
    <aside className="flex h-full flex-col border-r border-border bg-surface/60 backdrop-blur-xl">
      {/* Brand + signed-in identity + logout */}
      <div className="border-b border-border p-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-brand">
              <MessagesSquare className="h-4 w-4 text-white" aria-hidden />
            </div>
            <span className="text-sm font-semibold text-fg">Chat Platform</span>
          </div>
          <div className="flex items-center gap-1">
            <ThemeToggle />
            <IconButton label="Starred messages" onClick={onOpenStarred} type="button">
              <Star className="h-5 w-5" aria-hidden />
            </IconButton>
            <IconButton label="Log out" variant="danger" onClick={onLogout} type="button">
              <LogOut className="h-5 w-5" aria-hidden />
            </IconButton>
          </div>
        </div>

        {session ? (
          <button
            type="button"
            onClick={onOpenProfile}
            aria-label="Edit my profile"
            className="mt-3 flex w-full items-center gap-2.5 rounded-xl bg-elevated px-2.5 py-2 text-left transition-colors hover:bg-border"
          >
            <Avatar
              id={session.user_id}
              name={currentProfile?.display_name ?? undefined}
              imageUrl={currentProfile?.avatar_url}
              size="sm"
            />
            <div className="min-w-0">
              <p className="truncate text-sm font-medium text-fg">
                {currentProfile?.display_name || "Set up your profile"}
              </p>
              <p className="truncate text-xs text-faint">{shortId(session.user_id)}</p>
            </div>
          </button>
        ) : null}
      </div>

      {/* New conversation (collapsible to keep the list prominent) */}
      <details className="group border-b border-border" open>
        <summary className="flex cursor-pointer list-none items-center justify-between px-4 py-3 text-sm font-medium text-muted transition-colors hover:text-fg">
          <span className="flex items-center gap-2">
            <Plus className="h-4 w-4" aria-hidden />
            New conversation
          </span>
        </summary>

        <form className="space-y-3 px-4 pb-4" onSubmit={onCreateConversation}>
          <Input
            placeholder="Conversation title"
            value={newTitle}
            onChange={(event) => onNewTitleChange(event.target.value)}
          />

          <div className="space-y-2 rounded-xl border border-border bg-elevated p-2.5">
            <div className="flex gap-2">
              <Input
                leftIcon={<Search className="h-4 w-4" aria-hidden />}
                placeholder="Participant user ID"
                value={lookupUserId}
                onChange={(event) => onLookupUserIdChange(event.target.value)}
                className="bg-bg"
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
              <div className="flex items-center justify-between gap-2 rounded-lg bg-bg p-2">
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
      </details>

      {/* Message search (debounced, scoped to the caller's conversations) */}
      <MessageSearch
        conversations={conversations}
        currentUserId={session?.user_id}
        onJump={onJumpToMessage}
      />

      {/* Filter tabs — segmented control over the existing list, by conversation type. */}
      <div className="px-3 pt-3" role="tablist" aria-label="Filter conversations">
        <div className="flex gap-1 rounded-xl border border-border bg-elevated p-1">
          {FILTERS.map((option) => {
            const active = filter === option.key;
            return (
              <button
                key={option.key}
                type="button"
                role="tab"
                aria-selected={active}
                onClick={() => setFilter(option.key)}
                className={cn(
                  "flex-1 rounded-lg px-2 py-1.5 text-xs font-medium transition-all duration-150",
                  "outline-none focus-visible:ring-2 focus-visible:ring-brand-ring",
                  active ? "bg-surface text-fg shadow-subtle" : "text-muted hover:text-fg"
                )}
              >
                {option.label}
              </button>
            );
          })}
        </div>
      </div>

      {/* Conversation list */}
      <div className="flex-1 overflow-y-auto p-2">
        {isLoading ? (
          <EmptyState title="Loading conversations…" />
        ) : conversations.length === 0 ? (
          <EmptyState
            icon={<MessagesSquare className="h-6 w-6" aria-hidden />}
            title="No conversations yet"
            hint="Create one above to begin."
          />
        ) : filteredConversations.length === 0 ? (
          <EmptyState
            icon={<MessagesSquare className="h-6 w-6" aria-hidden />}
            title="No conversations here"
            hint={filter === "personal" ? "No 1:1 chats yet." : "No group chats yet."}
          />
        ) : (
          <div className="space-y-1">
            {filteredConversations.map((conversation) => (
              <ConversationListItem
                key={conversation.conversation_id}
                conversation={conversation}
                isSelected={selectedConversationId === conversation.conversation_id}
                onSelect={onSelectConversation}
              />
            ))}
          </div>
        )}
      </div>
    </aside>
  );
}
