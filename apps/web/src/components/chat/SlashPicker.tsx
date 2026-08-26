"use client";

import { useEffect, useMemo, useState } from "react";
import { Zap } from "lucide-react";
import type { QuickReply, SlashCommand, UserProfile } from "@/lib/api";
import { filterItems, pickerItems, type PickerItem } from "@/lib/slashCommands";

export type SlashPickerProps = {
  /** The text typed after "/" (empty right after the slash). */
  fragment: string;
  commands: SlashCommand[];
  quickReplies: QuickReply[];
  profile: UserProfile | null;
  onSelect: (item: PickerItem) => void;
  onDismiss: () => void;
};

/**
 * The "/" palette above the composer. Built-in commands (gated on the profile fields they need)
 * first, then the user's own quick replies. Keyboard-first: ↑/↓ move, Enter picks, Esc dismisses.
 */
export function SlashPicker({
  fragment,
  commands,
  quickReplies,
  profile,
  onSelect,
  onDismiss
}: SlashPickerProps) {
  const items = useMemo(
    () => filterItems(pickerItems(commands, quickReplies, profile), fragment),
    [commands, quickReplies, profile, fragment]
  );

  const [active, setActive] = useState(0);
  // Keep the highlight in range as the fragment narrows the list.
  const activeIndex = items.length === 0 ? 0 : Math.min(active, items.length - 1);

  useEffect(() => {
    function onKey(event: KeyboardEvent) {
      if (items.length === 0) return;

      if (event.key === "ArrowDown") {
        event.preventDefault();
        setActive((current) => (current + 1) % items.length);
      } else if (event.key === "ArrowUp") {
        event.preventDefault();
        setActive((current) => (current - 1 + items.length) % items.length);
      } else if (event.key === "Enter") {
        event.preventDefault();
        onSelect(items[Math.min(activeIndex, items.length - 1)]);
      } else if (event.key === "Escape") {
        event.preventDefault();
        onDismiss();
      }
    }

    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [items, activeIndex, onSelect, onDismiss]);

  if (items.length === 0) return null;

  return (
    <div className="mx-3 mb-2 overflow-hidden rounded-2xl border border-border bg-surface shadow-elevated">
      <p className="border-b border-border/60 px-3 py-1.5 text-[11px] font-medium text-faint">
        Commands
      </p>
      <ul className="max-h-56 overflow-y-auto py-1" role="listbox">
        {items.map((item, index) => (
          <li key={`${item.source}:${item.name}`}>
            <button
              type="button"
              role="option"
              aria-selected={index === activeIndex}
              // onMouseDown, not onClick: the composer input must not lose focus before we act.
              onMouseDown={(event) => {
                event.preventDefault();
                onSelect(item);
              }}
              onMouseEnter={() => setActive(index)}
              className={`flex w-full items-center gap-2 px-3 py-2 text-left transition-colors ${
                index === activeIndex ? "bg-brand-subtle" : "hover:bg-elevated"
              }`}
            >
              <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-md bg-brand-subtle text-brand-hover">
                <Zap className="h-3.5 w-3.5" aria-hidden />
              </span>
              <span className="min-w-0 flex-1">
                <span className="block text-sm font-medium text-fg">/{item.name}</span>
                {item.description ? (
                  <span className="block truncate text-[11px] text-faint">{item.description}</span>
                ) : null}
              </span>
              {item.source === "quick_reply" ? (
                <span className="shrink-0 rounded-full bg-elevated px-2 py-0.5 text-[10px] text-muted">
                  Quick reply
                </span>
              ) : null}
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}
