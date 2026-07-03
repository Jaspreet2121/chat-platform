import { cn } from "@/lib/cn";

export type StatusBannerProps = {
  message: string;
  tone?: "neutral" | "error";
};

/** A subtle floating banner for transient status/error text (replaces the old raw status line). */
export function StatusBanner({ message, tone = "neutral" }: StatusBannerProps) {
  if (!message) return null;

  return (
    <div className="pointer-events-none absolute inset-x-0 top-[4.5rem] z-10 flex justify-center px-4 animate-slide-up">
      <div
        className={cn(
          "pointer-events-auto max-w-md truncate rounded-full border px-3.5 py-1.5 text-xs font-medium shadow-elevated backdrop-blur",
          tone === "error"
            ? "border-danger/40 bg-danger/15 text-danger"
            : "border-border bg-surface/90 text-muted"
        )}
        role="status"
      >
        {message}
      </div>
    </div>
  );
}
