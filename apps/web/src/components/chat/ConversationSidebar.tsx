"use client";

import { FormEvent, useEffect, useState } from "react";
import { motion } from "framer-motion";
import { MessagesSquare, MoreVertical, SquarePen } from "lucide-react";
import type {
  ConversationListItem as ConversationListItemData,
  Session,
  UserProfile
} from "@/lib/api";
import { cn } from "@/lib/cn";
import { riseItem, staggerContainer } from "@/lib/motion";
import { ConversationListItem } from "./ConversationListItem";
import { ContactSearch } from "./ContactSearch";
import { EmptyState } from "./EmptyState";
import { MessageSearchModal } from "./MessageSearchModal";
import { NewConversationModal } from "./NewConversationModal";

type ConversationFilter = "all" | "unread" | "groups";

const FILTERS: { key: ConversationFilter; label: string }[] = [
  { key: "all", label: "All" },
  { key: "unread", label: "Unread" },
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

  /** Bumped by the rail's "New group" — opens the new-conversation modal (mode set by the parent). */
  openNewConvNonce?: number;
  /** Bumped by the rail's "Invite" — focuses the phone-number search (its empty state invites). */
  searchFocusNonce?: number;
};

export function ConversationSidebar(props: ConversationSidebarProps) {
  const {
    session,
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
    isLoading,
    openNewConvNonce,
    searchFocusNonce
  } = props;

  // Local UI state: new-conversation modal + message-search sheet (header actions).
  const [isNewConvOpen, setIsNewConvOpen] = useState(false);
  const [isMsgSearchOpen, setIsMsgSearchOpen] = useState(false);
  // Client-side filter by conversation state/type (a UI view of the existing list — no fetch).
  const [filter, setFilter] = useState<ConversationFilter>("all");
  const filteredConversations = conversations.filter((conversation) => {
    if (filter === "unread") return (conversation.unread_count ?? 0) > 0;
    if (filter === "groups") return conversation.type !== "direct";
    return true;
  });

  // Rail → open the new-conversation modal (e.g. in group mode; the parent set the mode first).
  // Deferred (timer) so setState never runs synchronously in the effect body.
  useEffect(() => {
    if (!openNewConvNonce) return;
    const handle = setTimeout(() => setIsNewConvOpen(true), 0);
    return () => clearTimeout(handle);
  }, [openNewConvNonce]);

  return (
    <aside className="flex h-full flex-col bg-surface md:border-r md:border-border">
      {/* Header: "Messages" + edit (new chat) on a soft periwinkle tile + overflow (search messages) */}
      <div className="flex items-center justify-between gap-2 px-4 pb-1 pt-3">
        <h1 className="text-lg font-semibold tracking-[-0.02em] text-fg">Messages</h1>
        <div className="flex shrink-0 items-center gap-1.5">
          <button
            type="button"
            onClick={() => {
              onConversationModeChange("direct");
              setIsNewConvOpen(true);
            }}
            aria-label="New chat"
            title="New chat"
            className="flex h-11 w-11 items-center justify-center rounded-xl bg-brand-subtle text-brand-hover md:h-9 md:w-9 transition-colors hover:bg-brand-subtle/70 outline-none focus-visible:ring-2 focus-visible:ring-brand-ring"
          >
            <SquarePen className="h-[18px] w-[18px]" aria-hidden />
          </button>
          <button
            type="button"
            onClick={() => setIsMsgSearchOpen(true)}
            aria-label="Search messages"
            title="Search messages"
            className="flex h-11 w-11 items-center justify-center rounded-xl text-muted md:h-9 md:w-9 transition-colors hover:bg-elevated hover:text-fg outline-none focus-visible:ring-2 focus-visible:ring-brand-ring"
          >
            <MoreVertical className="h-[18px] w-[18px]" aria-hidden />
          </button>
        </div>
      </div>

      {/* PRIMARY search (find by phone → chat/invite). Desktop: on top of the list. Mobile: moved to
          the BOTTOM of the pane (thumb reach) via order — the flex column reorders, nothing remounts. */}
      <div className="max-md:order-last max-md:border-t max-md:border-border">
        <ContactSearch onStartDirectChat={onStartDirectChat} focusNonce={searchFocusNonce} />
      </div>

      {/* Filter chips — active chip carries the accent gradient. */}
      <div className="flex gap-1.5 px-4 py-2" role="tablist" aria-label="Filter conversations">
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
                "rounded-full px-3.5 py-1.5 text-xs transition-all duration-150",
                "outline-none focus-visible:ring-2 focus-visible:ring-brand-ring",
                active
                  ? "accent-gradient font-medium text-white shadow-accent-glow"
                  : "bg-elevated text-muted hover:text-fg"
              )}
            >
              {option.label}
            </button>
          );
        })}
      </div>

      {/* Conversation list */}
      <div className="relative min-h-0 flex-1 overflow-y-auto pb-1">
        {isLoading ? (
          <EmptyState title="Loading conversations…" />
        ) : conversations.length === 0 ? (
          <EmptyState
            icon={<MessagesSquare className="h-6 w-6" aria-hidden />}
            title="No conversations yet"
            hint="Search a number below to start one."
          />
        ) : filteredConversations.length === 0 ? (
          <EmptyState
            icon={<MessagesSquare className="h-6 w-6" aria-hidden />}
            title="No conversations here"
            hint={filter === "unread" ? "You're all caught up." : "No group chats yet."}
          />
        ) : (
          <motion.div variants={staggerContainer} initial="hidden" animate="show">
            {filteredConversations.map((conversation) => (
              <motion.div key={conversation.conversation_id} variants={riseItem}>
                <ConversationListItem
                  conversation={conversation}
                  isSelected={selectedConversationId === conversation.conversation_id}
                  currentUserId={session?.user_id}
                  onSelect={onSelectConversation}
                />
              </motion.div>
            ))}
          </motion.div>
        )}

        {/* Mobile floating compose — sits above the bottom search bar, thumb-side. */}
        <button
          type="button"
          onClick={() => {
            onConversationModeChange("direct");
            setIsNewConvOpen(true);
          }}
          aria-label="New chat"
          className="accent-gradient fixed bottom-[148px] right-4 z-30 flex h-[52px] w-[52px] items-center justify-center rounded-full text-white shadow-accent-glow transition-transform active:scale-95 md:hidden"
        >
          <SquarePen className="h-5 w-5" aria-hidden />
        </button>
      </div>

      {/* New-conversation popup — same fields + handlers. */}
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

      {/* "Search messages" sheet. */}
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
