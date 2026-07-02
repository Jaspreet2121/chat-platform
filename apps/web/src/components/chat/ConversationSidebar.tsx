import { FormEvent, useState } from "react";
import { LogOut, MessagesSquare, Star } from "lucide-react";
import type {
  ConversationListItem as ConversationListItemData,
  Session,
  UserProfile
} from "@/lib/api";
import { Avatar, IconButton, ThemeToggle } from "@/components";
import { cn } from "@/lib/cn";
import { ConversationListItem } from "./ConversationListItem";
import { ContactSearch } from "./ContactSearch";
import { EmptyState } from "./EmptyState";
import { MessageSearchModal } from "./MessageSearchModal";
import { NewConversationModal } from "./NewConversationModal";
import { PlusMenu } from "./PlusMenu";

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
  /** Primary header search: start a 1:1 direct chat with a peer found by phone number. */
  onStartDirectChat: (profile: UserProfile) => void | Promise<void>;

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
    onStartDirectChat,
    conversations,
    selectedConversationId,
    onSelectConversation,
    onJumpToMessage,
    isLoading
  } = props;

  // Local UI state: the "+" menu's two entries — new-conversation modal + message-search sheet.
  const [isNewConvOpen, setIsNewConvOpen] = useState(false);
  const [isMsgSearchOpen, setIsMsgSearchOpen] = useState(false);
  // Client-side filter by conversation type (purely a UI view of the existing list — no fetch/handler).
  const [filter, setFilter] = useState<ConversationFilter>("all");
  const filteredConversations = conversations.filter((conversation) => {
    if (filter === "personal") return conversation.type === "direct";
    if (filter === "groups") return conversation.type !== "direct";
    return true;
  });

  return (
    // Flat, calm surface (WhatsApp-style): no glass blur, hairline right border.
    <aside className="flex h-full flex-col border-r border-border/60 bg-surface">
      {/* Compact header: small brand · quiet monochrome actions · slim identity row */}
      <div className="border-b border-border/60 px-3 py-2">
        <div className="flex items-center justify-between gap-1">
          <div className="flex min-w-0 items-center gap-2">
            <div className="flex h-7 w-7 shrink-0 items-center justify-center rounded-lg bg-brand/90">
              <MessagesSquare className="h-3.5 w-3.5 text-white" aria-hidden />
            </div>
            <span className="truncate text-sm font-medium text-fg">Chats</span>
          </div>
          <div className="flex shrink-0 items-center gap-0.5">
            <PlusMenu
              onNewChat={() => setIsNewConvOpen(true)}
              onSearchMessages={() => setIsMsgSearchOpen(true)}
            />
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
            className="mt-1.5 flex w-full items-center gap-2.5 rounded-lg px-1.5 py-1.5 text-left transition-colors hover:bg-elevated"
          >
            <Avatar
              id={session.user_id}
              name={currentProfile?.display_name ?? undefined}
              imageUrl={currentProfile?.avatar_url}
              size="sm"
            />
            <p className="min-w-0 flex-1 truncate text-sm text-fg">
              {currentProfile?.display_name || "Set up your profile"}
              <span className="ml-2 text-xs text-faint">{shortId(session.user_id)}</span>
            </p>
          </button>
        ) : null}
      </div>


      {/* PRIMARY search: find someone by phone number → start a direct chat (always visible). */}
      <ContactSearch onStartDirectChat={onStartDirectChat} />

      {/* Filter chips — light WhatsApp-style pills over the existing list, by conversation type. */}
      <div className="flex gap-1.5 px-3 py-2" role="tablist" aria-label="Filter conversations">
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
                "rounded-full px-3 py-1 text-xs transition-colors duration-150",
                "outline-none focus-visible:ring-2 focus-visible:ring-brand-ring",
                active
                  ? "bg-brand-subtle font-medium text-brand-hover"
                  : "text-muted hover:bg-elevated hover:text-fg"
              )}
            >
              {option.label}
            </button>
          );
        })}
      </div>

      {/* Conversation list — flat full-bleed rows with hairline separators. */}
      <div className="flex-1 overflow-y-auto">
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
          <div className="divide-y divide-border/30">
            {filteredConversations.map((conversation) => (
              <ConversationListItem
                key={conversation.conversation_id}
                conversation={conversation}
                isSelected={selectedConversationId === conversation.conversation_id}
                currentUserId={session?.user_id}
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

      {/* "Search messages" sheet — the message search relocated from the header into the "+" menu. */}
      <MessageSearchModal
        isOpen={isMsgSearchOpen}
        onClose={() => setIsMsgSearchOpen(false)}
        conversations={conversations}
        currentUserId={session?.user_id}
        onJump={onJumpToMessage}
      />
    </aside>
  );
}
