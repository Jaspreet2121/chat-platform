import { HTMLAttributes } from "react";
import { cn } from "@/lib/cn";

export type CardProps = HTMLAttributes<HTMLDivElement>;

export function Card({ className, ...props }: CardProps) {
  return (
    <div
      className={cn(
        // Crisp opaque white card + soft drop-shadow on light (pops on the gray page); frosted glass on
        // dark. Cohesive across all overlays (profile, starred, forward, public profile) + auth cards.
        "rounded-2xl border border-border bg-surface shadow-elevated dark:border-border/70 dark:bg-surface/80 dark:backdrop-blur-xl",
        className
      )}
      {...props}
    />
  );
}
