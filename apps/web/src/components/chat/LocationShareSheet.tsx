"use client";

import { useEffect, useState } from "react";
import { ChevronRight, MapPin, Radio, X } from "lucide-react";
import { Card } from "@/components";

const DURATIONS: { label: string; ms: number }[] = [
  { label: "15 minutes", ms: 15 * 60 * 1000 },
  { label: "1 hour", ms: 60 * 60 * 1000 },
  { label: "8 hours", ms: 8 * 60 * 60 * 1000 }
];

export type LocationShareSheetProps = {
  open: boolean;
  onClose: () => void;
  /** Send the current position as a one-off location message. */
  onSendCurrent: () => void;
  /** Start sharing live location for the given duration (ms). */
  onShareLive: (durationMs: number) => void;
};

// "Share location" chooser (opened from the composer "+" → Location). Two paths: a one-off current
// location, or live location with a duration. Matches the app's modal theme.
export function LocationShareSheet({ open, onClose, onSendCurrent, onShareLive }: LocationShareSheetProps) {
  const [pickDuration, setPickDuration] = useState(false);

  useEffect(() => {
    if (open) return;
    // Deferred so no setState runs synchronously in the effect body (reset for the next open).
    const t = setTimeout(() => setPickDuration(false), 0);
    return () => clearTimeout(t);
  }, [open]);

  useEffect(() => {
    if (!open) return;
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape") onClose();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open, onClose]);

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm animate-fade-in">
      <button type="button" aria-label="Close" onClick={onClose} className="absolute inset-0" />

      <Card className="relative w-full max-w-sm p-5 animate-scale-in">
        <div className="mb-4 flex items-center justify-between">
          <h2 className="text-base font-semibold text-fg">
            {pickDuration ? "Share live location" : "Share location"}
          </h2>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close"
            className="rounded-lg p-1.5 text-muted transition-colors hover:bg-elevated hover:text-fg"
          >
            <X className="h-4 w-4" aria-hidden />
          </button>
        </div>

        {pickDuration ? (
          <div className="space-y-2">
            <p className="px-1 text-sm text-muted">Choose how long to share:</p>
            {DURATIONS.map((d) => (
              <button
                key={d.ms}
                type="button"
                onClick={() => {
                  onShareLive(d.ms);
                  onClose();
                }}
                className="flex min-h-11 w-full items-center gap-3 rounded-xl border border-border px-3.5 py-2.5 text-left text-sm font-medium text-fg transition-colors hover:bg-elevated"
              >
                <Radio className="h-[18px] w-[18px] shrink-0 text-brand-hover" aria-hidden />
                {d.label}
              </button>
            ))}
            <p className="px-1 pt-1 text-[11px] leading-relaxed text-faint">
              Live location updates only while the app is open on this device — no background tracking.
            </p>
          </div>
        ) : (
          <div className="space-y-2">
            <SheetOption
              icon={<MapPin className="h-[18px] w-[18px]" aria-hidden />}
              title="Send current location"
              subtitle="Share where you are right now"
              onClick={() => {
                onSendCurrent();
                onClose();
              }}
            />
            <SheetOption
              icon={<Radio className="h-[18px] w-[18px]" aria-hidden />}
              title="Share live location"
              subtitle="Your location updates in real time, for a set time"
              chevron
              onClick={() => setPickDuration(true)}
            />
          </div>
        )}
      </Card>
    </div>
  );
}

function SheetOption({
  icon,
  title,
  subtitle,
  chevron,
  onClick
}: {
  icon: React.ReactNode;
  title: string;
  subtitle: string;
  chevron?: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="flex min-h-11 w-full items-center gap-3 rounded-xl px-3 py-2.5 text-left transition-colors hover:bg-elevated"
    >
      <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-brand-subtle text-brand-hover">
        {icon}
      </span>
      <span className="min-w-0 flex-1">
        <span className="block text-sm font-medium text-fg">{title}</span>
        <span className="block text-xs text-muted">{subtitle}</span>
      </span>
      {chevron ? <ChevronRight className="h-4 w-4 shrink-0 text-faint" aria-hidden /> : null}
    </button>
  );
}
