import { useEffect, useMemo, useRef, useState } from "react";
import { Loader2, MessageSquare, MessagesSquare } from "lucide-react";
import type { Message } from "@/lib/api";
import { Avatar } from "@/components";
import { cn } from "@/lib/cn";
import { EmptyState } from "./EmptyState";
import { MessageBubble } from "./MessageBubble";
import { formatTime, senderDisplayName } from "./format";
import { useUserProfile } from "./useUserProfile";

// Consecutive messages from the same sender within this window collapse into one group (one
// avatar+name header + a tight stack), like Telegram. Beyond it, a new group starts.
const GROUP_WINDOW_MS = 5 * 60 * 1000;

// Chronological order (oldest → newest) so the newest message sits just above the composer and
// auto-scroll lands on it. Sorting at render time covers BOTH history load and live socket
// messages (mergeMessage may append out of order). Ties break on message_id for a stable order.
function sortChronologically(messages: Message[]): Message[] {
  return [...messages].sort((a, b) => {
    const at = Date.parse(a.created_at);
    const bt = Date.parse(b.created_at);
    const aTime = Number.isNaN(at) ? 0 : at;
    const bTime = Number.isNaN(bt) ? 0 : bt;
    if (aTime !== bTime) return aTime - bTime;
    return a.message_id < b.message_id ? -1 : a.message_id > b.message_id ? 1 : 0;
  });
}

// Split an ordered message list into runs of consecutive same-sender messages (within GROUP_WINDOW_MS).
function buildGroups(messages: Message[]): Message[][] {
  const groups: Message[][] = [];
  for (const message of messages) {
    const current = groups[groups.length - 1];
    const prev = current?.[current.length - 1];
    const sameSender = prev?.sender_user_id === message.sender_user_id;
    const closeInTime =
      prev && Math.abs(Date.parse(message.created_at) - Date.parse(prev.created_at)) < GROUP_WINDOW_MS;
    if (current && sameSender && closeInTime) current.push(message);
    else groups.push([message]);
  }
  return groups;
}

// Date-divider label for a group's first message: Today / Yesterday / a readable date.
function dateLabel(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  const now = new Date();
  const startOf = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const diffDays = Math.round((startOf(now) - startOf(date)) / 86_400_000);
  if (diffDays === 0) return "Today";
  if (diffDays === 1) return "Yesterday";
  return date.toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
    year: date.getFullYear() === now.getFullYear() ? undefined : "numeric"
  });
}

function dayKey(iso: string): string {
  const date = new Date(iso);
  return Number.isNaN(date.getTime())
    ? ""
    : `${date.getFullYear()}-${date.getMonth()}-${date.getDate()}`;
}

export type MessageListProps = {
  messages: Message[];
  currentUserId?: string;
  isLoading: boolean;
  hasConversation: boolean;
  onEdit: (messageId: string, body: string) => Promise<void>;
  onDelete: (messageId: string) => Promise<void>;
  onReply?: (message: Message) => void;
  onForward?: (message: Message) => void;
  onReact?: (messageId: string, emoji: string) => void;
  onRemoveReaction?: (messageId: string) => void;
  onStar?: (messageId: string) => void;
  onUnstar?: (messageId: string) => void;
  /** A message to scroll to + highlight (from a search / starred result). The nonce re-triggers. */
  scrollTarget?: { id: string; n: number } | null;
};

export function MessageList({
  messages,
  currentUserId,
  isLoading,
  hasConversation,
  onEdit,
  onDelete,
  onReply,
  onForward,
  onReact,
  onRemoveReaction,
  onStar,
  onUnstar,
  scrollTarget
}: MessageListProps) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const [highlightedId, setHighlightedId] = useState<string | null>(null);
  // The last scroll-target nonce we've acted on, so an incoming message doesn't re-trigger the jump.
  const handledNonceRef = useRef<number | null>(null);
  const highlightTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const ordered = useMemo(() => sortChronologically(messages), [messages]);
  const groups = useMemo(() => buildGroups(ordered), [ordered]);
  // Lookup for resolving reply_to_message_id → the quoted message (when it's loaded).
  const byId = useMemo(() => {
    const map = new Map<string, Message>();
    for (const m of messages) map.set(m.message_id, m);
    return map;
  }, [messages]);

  // Keep the newest message in view as messages arrive (send + realtime) — UNLESS a jump-to-message is
  // pending, in which case we let the scroll effect below land on the target instead of the bottom.
  // Scrolls ONLY the list container (never scrollIntoView): scrollIntoView also scrolls every
  // scrollable ANCESTOR, and on iOS with the keyboard open that pans the whole document — leaving a
  // residual offset that clips the header when the keyboard closes.
  useEffect(() => {
    if (scrollTarget && handledNonceRef.current !== scrollTarget.n) return;
    const container = containerRef.current;
    if (!container) return;
    container.scrollTo({ top: container.scrollHeight, behavior: "smooth" });
  }, [messages.length, scrollTarget]);

  // Scroll to + briefly highlight a search/starred target once it's loaded. Nonce-guarded so it fires
  // once per jump (not on every subsequent message). If the target isn't in the loaded page (an older
  // message beyond the fetched window), we do nothing — "load around a message" is out of scope here.
  useEffect(() => {
    if (!scrollTarget) return;
    if (handledNonceRef.current === scrollTarget.n) return;
    if (!messages.some((message) => message.message_id === scrollTarget.id)) return;

    handledNonceRef.current = scrollTarget.n;
    // Defer to the next frame so the target node is laid out; also keeps setState out of the effect body.
    const raf = requestAnimationFrame(() => {
      const node = document.getElementById(`msg-${scrollTarget.id}`);
      const container = containerRef.current;
      if (!node || !container) return;
      // Center the target within the LIST only (container-confined; see the bottom-pin note above).
      const nodeTop = node.getBoundingClientRect().top - container.getBoundingClientRect().top;
      const top = container.scrollTop + nodeTop - container.clientHeight / 2 + node.clientHeight / 2;
      container.scrollTo({ top: Math.max(0, top), behavior: "smooth" });
      setHighlightedId(scrollTarget.id);
      if (highlightTimerRef.current) clearTimeout(highlightTimerRef.current);
      highlightTimerRef.current = setTimeout(() => setHighlightedId(null), 2200);
    });
    return () => cancelAnimationFrame(raf);
  }, [scrollTarget, messages]);

  // Clear the highlight timer on unmount (the timer lives in a ref so it survives effect re-runs).
  useEffect(() => {
    return () => {
      if (highlightTimerRef.current) clearTimeout(highlightTimerRef.current);
    };
  }, []);

  if (!hasConversation) {
    return (
      <div className="chat-ambient flex-1">
        <EmptyState
          icon={<MessagesSquare className="h-6 w-6" aria-hidden />}
          title="Select or create a conversation"
          hint="Pick a conversation from the sidebar, or start a new one to begin chatting."
        />
      </div>
    );
  }

  if (isLoading) {
    return (
      <div className="chat-ambient flex flex-1 items-center justify-center text-faint">
        <Loader2 className="h-5 w-5 animate-spin" aria-hidden />
      </div>
    );
  }

  if (messages.length === 0) {
    return (
      <div className="chat-ambient flex-1">
        <EmptyState
          icon={<MessageSquare className="h-6 w-6" aria-hidden />}
          title="No messages yet"
          hint="Say hello — your first message will appear here."
        />
      </div>
    );
  }

  return (
    <div
      ref={containerRef}
      className="chat-ambient min-h-0 flex-1 space-y-4 overflow-y-auto px-4 py-5 sm:px-6"
    >
      {groups.map((group, index) => {
        const previous = groups[index - 1];
        const newDay =
          !previous || dayKey(previous[0].created_at) !== dayKey(group[0].created_at);
        return (
          <div key={group[0].message_id} className="space-y-4">
            {newDay ? (
              // Date-divider pill (Today / Yesterday / date) — quiet periwinkle-tinted chip.
              <div className="flex justify-center">
                <span className="rounded-full bg-brand-subtle px-3 py-1 text-[11px] font-medium text-brand-hover shadow-subtle">
                  {dateLabel(group[0].created_at)}
                </span>
              </div>
            ) : null}
            <MessageGroup
              group={group}
              currentUserId={currentUserId}
              highlightedId={highlightedId}
              byId={byId}
              onEdit={onEdit}
              onDelete={onDelete}
              onReply={onReply}
              onForward={onForward}
              onReact={onReact}
              onRemoveReaction={onRemoveReaction}
              onStar={onStar}
              onUnstar={onUnstar}
            />
          </div>
        );
      })}
    </div>
  );
}

type MessageGroupProps = {
  group: Message[];
  currentUserId?: string;
  highlightedId: string | null;
  byId: Map<string, Message>;
} & Pick<
  MessageListProps,
  "onEdit" | "onDelete" | "onReply" | "onForward" | "onReact" | "onRemoveReaction" | "onStar" | "onUnstar"
>;

// One run of consecutive same-sender messages: for others, a single avatar + name + time header, then a
// tight stack of that sender's bubbles (avatars hidden on the bubbles); own groups are just the stack.
function MessageGroup({
  group,
  currentUserId,
  highlightedId,
  byId,
  onEdit,
  onDelete,
  onReply,
  onForward,
  onReact,
  onRemoveReaction,
  onStar,
  onUnstar
}: MessageGroupProps) {
  const first = group[0];
  const isOwn = first.sender_user_id === currentUserId;
  const profile = useUserProfile(isOwn ? null : first.sender_user_id);
  const name = senderDisplayName(profile?.display_name);

  return (
    <div className={cn("flex flex-col", isOwn ? "items-end" : "items-start")}>
      {!isOwn ? (
        <div className="mb-1 flex items-center gap-2 pl-1">
          <Avatar
            id={first.sender_user_id}
            name={profile?.display_name ?? undefined}
            imageUrl={profile?.avatar_url}
            size="sm"
          />
          <span className="text-xs font-semibold text-fg">{name}</span>
          <span className="text-[11px] text-faint">{formatTime(first.created_at)}</span>
        </div>
      ) : null}

      <div className={cn("flex w-full flex-col gap-0.5", isOwn ? "items-end" : "items-start pl-10")}>
        {group.map((message) => (
          <MessageBubble
            key={message.message_id}
            message={message}
            isOwn={isOwn}
            hideAvatar
            isHighlighted={highlightedId === message.message_id}
            currentUserId={currentUserId}
            quoted={
              message.reply_to_message_id ? byId.get(message.reply_to_message_id) ?? null : null
            }
            onEdit={onEdit}
            onDelete={onDelete}
            onReply={onReply}
            onForward={onForward}
            onReact={onReact}
            onRemoveReaction={onRemoveReaction}
            onStar={onStar}
            onUnstar={onUnstar}
          />
        ))}
      </div>
    </div>
  );
}
