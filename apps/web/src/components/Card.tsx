import { HTMLAttributes } from "react";
import { cn } from "@/lib/cn";

export type CardProps = HTMLAttributes<HTMLDivElement>;

export function Card({ className, ...props }: CardProps) {
  return (
    <div
      className={cn(
        // Frosted-glass card: translucent surface + blur so it floats over the ambient backdrop.
        // Cohesive across all overlays (profile, starred, forward, public profile) and auth cards.
        "rounded-2xl border border-border/70 bg-surface/80 shadow-elevated backdrop-blur-xl",
        className
      )}
      {...props}
    />
  );
}
