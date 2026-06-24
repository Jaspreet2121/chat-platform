import { useMemo } from "react";
import { cn } from "@/lib/cn";

export type AvatarProps = {
  /** Stable identifier used to pick a consistent color (e.g. user id). */
  id: string;
  /** Display name or label; initials are derived from it (falls back to id). */
  name?: string;
  size?: "sm" | "md" | "lg";
  /** When true, overlays a small green presence dot (bottom-right). */
  online?: boolean;
  className?: string;
};

const dotSizes = {
  sm: "h-2.5 w-2.5",
  md: "h-3 w-3",
  lg: "h-3.5 w-3.5"
};

// A small, pleasant palette of gradient pairs. The id hash picks one deterministically,
// so a given user always gets the same color across sessions.
const palettes = [
  "from-indigo-500 to-violet-500",
  "from-sky-500 to-cyan-500",
  "from-emerald-500 to-teal-500",
  "from-rose-500 to-pink-500",
  "from-amber-500 to-orange-500",
  "from-fuchsia-500 to-purple-500"
];

const sizes = {
  sm: "h-8 w-8 text-xs",
  md: "h-10 w-10 text-sm",
  lg: "h-12 w-12 text-base"
};

function hash(value: string): number {
  let h = 0;
  for (let i = 0; i < value.length; i += 1) {
    h = (h << 5) - h + value.charCodeAt(i);
    h |= 0;
  }
  return Math.abs(h);
}

function initials(label: string): string {
  const parts = label.trim().split(/[\s_-]+/).filter(Boolean);
  if (parts.length === 0) return "?";
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

export function Avatar({ id, name, size = "md", online, className }: AvatarProps) {
  const label = name?.trim() || id;
  const palette = useMemo(() => palettes[hash(id) % palettes.length], [id]);

  return (
    <div className="relative inline-flex shrink-0">
      <div
        className={cn(
          "flex items-center justify-center rounded-full bg-gradient-to-br font-semibold text-white",
          palette,
          sizes[size],
          className
        )}
        aria-hidden
      >
        {initials(label)}
      </div>
      {online ? (
        <span
          className={cn(
            "absolute bottom-0 right-0 rounded-full border-2 border-surface bg-success",
            dotSizes[size]
          )}
          aria-label="Online"
          title="Online"
        />
      ) : null}
    </div>
  );
}
