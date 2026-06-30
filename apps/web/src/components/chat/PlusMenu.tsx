"use client";

import { ReactNode, useEffect, useRef, useState } from "react";
import { Plus, Search, SquarePen } from "lucide-react";
import { IconButton } from "@/components";
import { cn } from "@/lib/cn";

export type PlusMenuProps = {
  /** Open the New conversation modal (Direct/Group). */
  onNewChat: () => void;
  /** Open the Search messages sheet. */
  onSearchMessages: () => void;
};

// The "+" entry: a small popover menu with "New chat" and "Search messages". Self-contained — owns its
// open state, toggles on the trigger, and closes on outside-click / Esc (trigger lives inside the ref,
// so clicking it toggles cleanly rather than close-then-reopen).
export function PlusMenu({ onNewChat, onSearchMessages }: PlusMenuProps) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!open) return;
    function onDown(event: MouseEvent) {
      if (ref.current && !ref.current.contains(event.target as Node)) setOpen(false);
    }
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape") setOpen(false);
    }
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  function choose(action: () => void) {
    setOpen(false);
    action();
  }

  return (
    <div ref={ref} className="relative">
      <IconButton
        label="New conversation"
        variant="primary"
        onClick={() => setOpen((value) => !value)}
        type="button"
        aria-haspopup="menu"
        aria-expanded={open}
      >
        <Plus className="h-5 w-5" aria-hidden />
      </IconButton>

      {open ? (
        <div
          role="menu"
          aria-label="New conversation menu"
          className="absolute right-0 top-full z-30 mt-2 w-60 overflow-hidden rounded-2xl border border-border bg-surface/95 p-1.5 shadow-glow-sm backdrop-blur-xl animate-bubble-in"
        >
          <MenuItem
            icon={<SquarePen className="h-4 w-4" aria-hidden />}
            title="New chat"
            subtitle="Start a direct or group chat"
            onClick={() => choose(onNewChat)}
          />
          <MenuItem
            icon={<Search className="h-4 w-4" aria-hidden />}
            title="Search messages"
            subtitle="Find within your conversations"
            onClick={() => choose(onSearchMessages)}
          />
        </div>
      ) : null}
    </div>
  );
}

function MenuItem({
  icon,
  title,
  subtitle,
  onClick
}: {
  icon: ReactNode;
  title: string;
  subtitle: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      role="menuitem"
      onClick={onClick}
      className={cn(
        "flex w-full items-center gap-3 rounded-xl px-2.5 py-2 text-left transition-colors",
        "outline-none hover:bg-elevated focus-visible:bg-elevated focus-visible:ring-2 focus-visible:ring-brand-ring"
      )}
    >
      <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-brand-subtle text-brand-hover">
        {icon}
      </span>
      <span className="min-w-0">
        <span className="block truncate text-sm font-medium text-fg">{title}</span>
        <span className="block truncate text-xs text-faint">{subtitle}</span>
      </span>
    </button>
  );
}
