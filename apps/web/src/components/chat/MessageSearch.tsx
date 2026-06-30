"use client";

import { Fragment, useEffect, useState } from "react";
import { Loader2, Search, X } from "lucide-react";
import type { ConversationListItem, Message } from "@/lib/api";
import { searchMessages } from "@/lib/api";
import { Input } from "@/components";
import { formatTime } from "./format";

const MIN_QUERY = 2;
const DEBOUNCE_MS = 300;

export type MessageSearchProps = {
  conversations: ConversationListItem[];
  currentUserId?: string;
  /** Open the conversation a result belongs to and scroll to the matched message. */
  onJump: (conversationId: string, messageId: string) => void;
  /** Focus the input on mount (used when shown in the search sheet). */
  autoFocus?: boolean;
  /** Called after a result is opened (lets a host sheet close itself). */
  onJumped?: () => void;
};

// Message search: debounced, ≥2 chars, scoped server-side to the caller's conversations. Rendered
// inside the "+" → Search messages sheet (chrome is provided by the host).
export function MessageSearch({
  conversations,
  currentUserId,
  onJump,
  autoFocus,
  onJumped
}: MessageSearchProps) {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<Message[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [searched, setSearched] = useState(false);

  const trimmed = query.trim();
  const active = trimmed.length >= MIN_QUERY;

  useEffect(() => {
    let cancelled = false;

    // All state updates run in deferred callbacks (timer / promise), never synchronously in the effect
    // body — keeps the debounce idiomatic and avoids cascading renders.
    if (!active) {
      const reset = setTimeout(() => {
        if (cancelled) return;
        setResults([]);
        setSearched(false);
        setIsLoading(false);
      }, 0);
      return () => {
        cancelled = true;
        clearTimeout(reset);
      };
    }

    const handle = setTimeout(() => {
      setIsLoading(true);
      searchMessages(trimmed)
        .then((res) => {
          if (cancelled) return;
          setResults(res.messages ?? []);
          setSearched(true);
        })
        .catch(() => {
          if (cancelled) return;
          setResults([]);
          setSearched(true);
        })
        .finally(() => {
          if (!cancelled) setIsLoading(false);
        });
    }, DEBOUNCE_MS);

    return () => {
      cancelled = true;
      clearTimeout(handle);
    };
  }, [active, trimmed]);

  function titleFor(conversationId: string) {
    return (
      conversations.find((c) => c.conversation_id === conversationId)?.title ||
      `#${conversationId.slice(0, 8)}`
    );
  }

  function jump(conversationId: string, messageId: string) {
    onJump(conversationId, messageId);
    setQuery("");
    onJumped?.();
  }

  return (
    <div>
      <div className="relative">
        <Input
          leftIcon={<Search className="h-4 w-4" aria-hidden />}
          placeholder="Search messages"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          className={query ? "pr-9" : undefined}
          aria-label="Search messages"
          autoFocus={autoFocus}
        />
        {query ? (
          <button
            type="button"
            onClick={() => setQuery("")}
            aria-label="Clear search"
            className="absolute right-2 top-1/2 -translate-y-1/2 rounded p-1 text-faint transition-colors hover:text-fg"
          >
            <X className="h-4 w-4" aria-hidden />
          </button>
        ) : null}
      </div>

      {active ? (
        <div className="mt-2 max-h-72 overflow-y-auto">
          {isLoading ? (
            <div className="flex justify-center py-4 text-faint">
              <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
            </div>
          ) : results.length === 0 ? (
            searched ? <p className="py-4 text-center text-xs text-muted">No results</p> : null
          ) : (
            <ul className="space-y-1">
              {results.map((message) => (
                <li key={message.message_id}>
                  <button
                    type="button"
                    onClick={() => jump(message.conversation_id, message.message_id)}
                    className="w-full rounded-lg px-2.5 py-2 text-left transition-colors hover:bg-elevated"
                  >
                    <div className="flex items-baseline justify-between gap-2">
                      <span className="truncate text-xs font-medium text-fg">
                        {titleFor(message.conversation_id)}
                      </span>
                      <span className="shrink-0 text-[10px] text-faint">
                        {formatTime(message.created_at)}
                      </span>
                    </div>
                    <p className="truncate text-xs text-muted">
                      <span className="text-faint">
                        {message.sender_user_id === currentUserId
                          ? "You: "
                          : `#${message.sender_user_id.slice(0, 8)}: `}
                      </span>
                      {highlight(message.body ?? "", trimmed)}
                    </p>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      ) : null}
    </div>
  );
}

// Case-insensitive highlight of the matched term in a snippet (first occurrence onwards, all matches).
function highlight(text: string, term: string) {
  if (!term) return text;
  const lower = text.toLowerCase();
  const needle = term.toLowerCase();
  const parts: Array<{ text: string; match: boolean }> = [];
  let index = 0;

  while (index < text.length) {
    const found = lower.indexOf(needle, index);
    if (found === -1) {
      parts.push({ text: text.slice(index), match: false });
      break;
    }
    if (found > index) parts.push({ text: text.slice(index, found), match: false });
    parts.push({ text: text.slice(found, found + needle.length), match: true });
    index = found + needle.length;
  }

  return parts.map((part, i) =>
    part.match ? (
      <mark key={i} className="rounded bg-amber-400/30 text-fg">
        {part.text}
      </mark>
    ) : (
      <Fragment key={i}>{part.text}</Fragment>
    )
  );
}
