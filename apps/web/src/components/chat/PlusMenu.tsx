"use client";

import { ReactNode, useEffect, useLayoutEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { Plus, Search, SquarePen } from "lucide-react";
import { IconButton } from "@/components";
import { cn } from "@/lib/cn";

export type PlusMenuProps = {
  /** Open the New conversation modal (Direct/Group). */
  onNewChat: () => void;
  /** Open the Search messages sheet. */
  onSearchMessages: () => void;
};

const MENU_WIDTH = 240; // matches w-60
const EDGE = 8; // min gap from any viewport edge

// The "+" entry: a popover menu with "New chat" and "Search messages". The popover is PORTALED to
// <body> and fixed-positioned from the trigger's rect, clamped to the viewport — the sidebar's
// `backdrop-blur` aside is a clipping stacking context (and the app root is overflow-hidden), so an
// in-flow absolute popover was cut off at the sidebar's left edge / covered by the chat pane. Portaling
// escapes both. Closes on outside-click (trigger OR menu) and Esc.
export function PlusMenu({ onNewChat, onSearchMessages }: PlusMenuProps) {
  const [open, setOpen] = useState(false);
  const [pos, setPos] = useState<{ top: number; left: number } | null>(null);
  const triggerRef = useRef<HTMLDivElement | null>(null);
  const menuRef = useRef<HTMLDivElement | null>(null);

  // Position the menu under the trigger, right-aligned to it, clamped fully on-screen.
  useLayoutEffect(() => {
    if (!open) return;

    function place() {
      const el = triggerRef.current;
      if (!el) return;
      const r = el.getBoundingClientRect();
      const maxLeft = window.innerWidth - MENU_WIDTH - EDGE;
      const left = Math.min(Math.max(EDGE, r.right - MENU_WIDTH), Math.max(EDGE, maxLeft));
      setPos({ top: r.bottom + 8, left });
    }

    place();
    window.addEventListener("resize", place);
    window.addEventListener("scroll", place, true);
    return () => {
      window.removeEventListener("resize", place);
      window.removeEventListener("scroll", place, true);
    };
  }, [open]);

  useEffect(() => {
    if (!open) return;
    function onDown(event: MouseEvent) {
      const target = event.target as Node;
      if (triggerRef.current?.contains(target)) return;
      if (menuRef.current?.contains(target)) return;
      setOpen(false);
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
    <div ref={triggerRef} className="relative">
      <IconButton
        label="New conversation"
        variant="ghost"
        onClick={() => setOpen((value) => !value)}
        type="button"
        aria-haspopup="menu"
        aria-expanded={open}
      >
        <Plus className="h-5 w-5" aria-hidden />
      </IconButton>

      {open && pos && typeof document !== "undefined"
        ? createPortal(
            <div
              ref={menuRef}
              role="menu"
              aria-label="New conversation menu"
              style={{ position: "fixed", top: pos.top, left: pos.left, width: MENU_WIDTH }}
              className="z-[70] overflow-hidden rounded-2xl border border-border bg-surface/95 p-1.5 shadow-glow-sm backdrop-blur-xl animate-bubble-in"
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
            </div>,
            document.body
          )
        : null}
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
