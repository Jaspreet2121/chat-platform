import { FormEvent, useState } from "react";
import { LogOut, MessagesSquare, Plus, Star } from "lucide-react";
import type {
  ConversationListItem as ConversationListItemData,
  Session,
  UserProfile
} from "@/lib/api";
import { Avatar, IconButton, ThemeToggle } from "@/components";
import { cn } from "@/lib/cn";
import { ConversationListItem } from "./ConversationListItem";
import { EmptyState } from "./EmptyState";
import { MessageSearch } from "./MessageSearch";
import { NewConversationModal } from "./NewConversationModal";

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
  conversationMode: "direct" | "group";
  onConversationModeChange: (mode: "direct" | "group") => void;
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
  /** Direct mode: set the single peer resolved from a phone-number lookup. */
  onSelectFoundUser: (profile: UserProfile) => void;

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

export function ConversationSidebar(props: ConversationSidebarProps) {
  const {
    session,
    currentProfile,
    onLogout,
    onOpenStarred,
    onOpenProfile,
    newTitle,
    onNewTitleChange,
    conversationMode,
    onConversationModeChange,
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
    onSelectFoundUser,
    conversations,
    selectedConversationId,
    onSelectConversation,
    onJumpToMessage,
    isLoading
  } = props;

  // Local UI state: the new-conversation modal (the create/lookup handlers still come from props).
  const [isNewConvOpen, setIsNewConvOpen] = useState(false);
  // Client-side filter by conversation type (purely a UI view of the existing list — no fetch/handler).
  const [filter, setFilter] = useState<ConversationFilter>("all");
  const filteredConversations = conversations.filter((conversation) => {
    if (filter === "personal") return conversation.type === "direct";
    if (filter === "groups") return conversation.type !== "direct";
    return true;
  });

  return (
    <aside className="flex h-full flex-col border-r border-border bg-surface/60 backdrop-blur-xl">
      {/* Compact header: brand · actions (new conversation, theme, starred, logout) · identity */}
      <div className="border-b border-border p-3">
        <div className="flex items-center justify-between gap-1">
          <div className="flex min-w-0 items-center gap-2">
            <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-brand">
              <MessagesSquare className="h-4 w-4 text-white" aria-hidden />
            </div>
            <span className="truncate text-sm font-semibold text-fg">Chat Platform</span>
          </div>
          <div className="flex shrink-0 items-center gap-0.5">
            <IconButton
              label="New conversation"
              variant="primary"
              onClick={() => setIsNewConvOpen(true)}
              type="button"
            >
              <Plus className="h-5 w-5" aria-hidden />
            </IconButton>
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
                  active
                    ? "bg-brand-subtle text-brand-hover shadow-subtle ring-1 ring-inset ring-brand/20"
                    : "text-muted hover:text-fg"
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

      {/* New-conversation popup — same fields + handlers, relocated from the sidebar body. */}
      <NewConversationModal
        isOpen={isNewConvOpen}
        onClose={() => setIsNewConvOpen(false)}
        newTitle={newTitle}
        onNewTitleChange={onNewTitleChange}
        mode={conversationMode}
        onModeChange={onConversationModeChange}
        onCreateConversation={onCreateConversation}
        isCreatingConversation={isCreatingConversation}
        lookupUserId={lookupUserId}
        onLookupUserIdChange={onLookupUserIdChange}
        onLookup={onLookup}
        isLookingUpProfile={isLookingUpProfile}
        lookupStatus={lookupStatus}
        lookupProfile={lookupProfile}
        onAddParticipant={onAddParticipant}
        selectedParticipants={selectedParticipants}
        onRemoveParticipant={onRemoveParticipant}
        onSelectFoundUser={onSelectFoundUser}
      />
    </aside>
  );
}
