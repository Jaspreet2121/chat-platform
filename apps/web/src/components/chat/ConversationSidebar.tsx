"use client";

import { FormEvent, useEffect, useRef, useState } from "react";
import { motion } from "framer-motion";
import { MessagesSquare, MoreVertical, Search, SquarePen } from "lucide-react";
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
  onCreateConversation: (event: FormEvent<HTMLFormElement>) => void;
  isCreatingConversation: boolean;

  /** Append a phone-resolved group participant (deduped by the parent). */
  onAddParticipant: (profile: UserProfile) => void;
  selectedParticipants: UserProfile[];
  onRemoveParticipant: (userId: string) => void;
  /** Primary header search: start a 1:1 direct chat with a peer found by phone number. */
  onStartDirectChat: (profile: UserProfile) => void | Promise<void>;

  conversations: ConversationListItemData[];
  selectedConversationId: string;
  onSelectConversation: (conversationId: string) => void;
  /** Open a conversation AND scroll to a specific message (used by search results). */
  onJumpToMessage: (conversationId: string, messageId: string) => void;
  isLoading: boolean;

  /** Bumped by the rail's "New group" — opens the new-group modal. */
  openNewConvNonce?: number;
  /** Bumped by the rail's "Invite" — focuses the phone-number search (its empty state invites). */
  searchFocusNonce?: number;
  /** Hide the floating compose FAB (mobile keyboard open — it would ride up mid-screen otherwise). */
  fabHidden?: boolean;
};

export function ConversationSidebar(props: ConversationSidebarProps) {
  const {
    session,
    newTitle,
    onNewTitleChange,
    onCreateConversation,
    isCreatingConversation,
    onAddParticipant,
    selectedParticipants,
    onRemoveParticipant,
    onStartDirectChat,
    conversations,
    selectedConversationId,
    onSelectConversation,
    onJumpToMessage,
    isLoading,
    openNewConvNonce,
    searchFocusNonce,
    fabHidden
  } = props;

  // Local UI state: new-group modal + message-search sheet (header actions), and a local bump for
  // focusing the phone search (the edit button/FAB start a DM there — no type-picker step).
  const [isNewConvOpen, setIsNewConvOpen] = useState(false);
  const [localFocusNonce, setLocalFocusNonce] = useState(0);
  const [isMsgSearchOpen, setIsMsgSearchOpen] = useState(false);
  // Header 3-dot dropdown (list-level actions; entries open their own UI).
  const [isHeaderMenuOpen, setIsHeaderMenuOpen] = useState(false);
  const headerMenuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!isHeaderMenuOpen) return;
    function onDown(event: MouseEvent | TouchEvent) {
      if (headerMenuRef.current && !headerMenuRef.current.contains(event.target as Node)) {
        setIsHeaderMenuOpen(false);
      }
    }
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape") setIsHeaderMenuOpen(false);
    }
    document.addEventListener("mousedown", onDown);
    document.addEventListener("touchstart", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("touchstart", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [isHeaderMenuOpen]);
  // Client-side filter by conversation state/type (a UI view of the existing list — no fetch).
  const [filter, setFilter] = useState<ConversationFilter>("all");
  const filteredConversations = conversations
    .filter((conversation) => {
      if (filter === "unread") return (conversation.unread_count ?? 0) > 0;
      if (filter === "groups") return conversation.type !== "direct";
      return true;
    })
    // Most-recent activity first, LIVE: updated_at is the last-message time (server) and is bumped
    // client-side on send/incoming events, so a new message floats its conversation to the top.
    .sort((a, b) => Date.parse(b.updated_at ?? "") - Date.parse(a.updated_at ?? ""));

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
            onClick={() => setLocalFocusNonce((n) => n + 1)}
            aria-label="New chat"
            title="New chat — search a number"
            className="flex h-11 w-11 items-center justify-center rounded-xl bg-brand-subtle text-brand-hover md:h-9 md:w-9 transition-colors hover:bg-brand-subtle/70 outline-none focus-visible:ring-2 focus-visible:ring-brand-ring"
          >
            <SquarePen className="h-[18px] w-[18px]" aria-hidden />
          </button>
          <div ref={headerMenuRef} className="relative">
            <button
              type="button"
              onClick={() => setIsHeaderMenuOpen((v) => !v)}
              aria-label="More options"
              aria-haspopup="menu"
              aria-expanded={isHeaderMenuOpen}
              title="More options"
              className="flex h-11 w-11 items-center justify-center rounded-xl text-muted md:h-9 md:w-9 transition-colors hover:bg-elevated hover:text-fg outline-none focus-visible:ring-2 focus-visible:ring-brand-ring"
            >
              <MoreVertical className="h-[18px] w-[18px]" aria-hidden />
            </button>

            {isHeaderMenuOpen ? (
              <div
                role="menu"
                className="absolute right-0 top-full z-40 mt-1 w-48 overflow-hidden rounded-xl border border-border bg-surface p-1 shadow-elevated animate-scale-in"
              >
                <button
                  type="button"
                  role="menuitem"
                  onClick={() => {
                    setIsHeaderMenuOpen(false);
                    setIsMsgSearchOpen(true);
                  }}
                  className="flex min-h-11 w-full items-center gap-2.5 rounded-lg px-3 py-2 text-left text-sm text-fg transition-colors hover:bg-elevated"
                >
                  <Search className="h-4 w-4 text-muted" aria-hidden />
                  Search messages
                </button>
                <button
                  type="button"
                  role="menuitem"
                  onClick={() => {
                    setIsHeaderMenuOpen(false);
                    setIsNewConvOpen(true);
                  }}
                  className="flex min-h-11 w-full items-center gap-2.5 rounded-lg px-3 py-2 text-left text-sm text-fg transition-colors hover:bg-elevated"
                >
                  <MessagesSquare className="h-4 w-4 text-muted" aria-hidden />
                  New group
                </button>
              </div>
            ) : null}
          </div>
        </div>
      </div>

      {/* PRIMARY search (find by phone → chat/invite). Desktop: on top of the list. Mobile: moved to
          the BOTTOM of the pane (thumb reach) via order — the flex column reorders, nothing remounts. */}
      <div className="max-md:order-last max-md:border-t max-md:border-border">
        <ContactSearch onStartDirectChat={onStartDirectChat} focusNonce={(searchFocusNonce ?? 0) + localFocusNonce} />
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
          onClick={() => setLocalFocusNonce((n) => n + 1)}
          aria-label="New chat"
          className={cn(
            "accent-gradient fixed bottom-[calc(168px+env(safe-area-inset-bottom))] right-4 z-30 flex h-[52px] w-[52px] items-center justify-center rounded-full text-white shadow-accent-glow transition-transform active:scale-95 md:hidden",
            fabHidden && "hidden"
          )}
        >
          <SquarePen className="h-5 w-5" aria-hidden />
        </button>
      </div>

      {/* New-group popup (participants added by phone number). */}
      <NewConversationModal
        isOpen={isNewConvOpen}
        onClose={() => setIsNewConvOpen(false)}
        newTitle={newTitle}
        onNewTitleChange={onNewTitleChange}
        onCreateConversation={onCreateConversation}
        isCreatingConversation={isCreatingConversation}
        onAddParticipant={onAddParticipant}
        selectedParticipants={selectedParticipants}
        onRemoveParticipant={onRemoveParticipant}
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
