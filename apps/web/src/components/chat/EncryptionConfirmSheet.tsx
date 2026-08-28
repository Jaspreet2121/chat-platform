"use client";

import { Lock } from "lucide-react";
import { Button } from "@/components";

export type EncryptionConfirmSheetProps = {
  busy: boolean;
  error: string | null;
  onConfirm: () => void;
  onCancel: () => void;
};

/** The one-way "Turn on encryption" confirm (108). */
export function EncryptionConfirmSheet({
  busy,
  error,
  onConfirm,
  onCancel
}: EncryptionConfirmSheetProps) {
  return (
    <div
      className="fixed inset-0 z-50 flex items-end justify-center bg-black/50 p-0 backdrop-blur-sm sm:items-center sm:p-6"
      role="dialog"
      aria-modal="true"
      aria-label="Turn on encryption"
    >
      <div className="w-full max-w-sm rounded-t-3xl bg-surface p-6 shadow-elevated sm:rounded-3xl">
        <div className="accent-gradient mx-auto flex h-12 w-12 items-center justify-center rounded-2xl shadow-accent-glow">
          <Lock className="h-6 w-6 text-white" aria-hidden />
        </div>
        <h2 className="mt-4 text-center text-lg font-semibold text-fg">Turn on encryption?</h2>
        <ul className="mt-3 space-y-1.5 text-sm text-muted">
          <li>• Messages become end-to-end encrypted — only you two can read them.</li>
          <li>• Both of you need to have opened Growblic at least once so your keys are registered.</li>
          <li>• This can&apos;t be turned back off — to leave, start a new chat.</li>
          <li>• Attachments aren&apos;t available in encrypted chats yet.</li>
        </ul>

        {error ? (
          <p className="mt-3 rounded-xl bg-red-500/10 px-3 py-2 text-sm text-red-500" role="alert">
            {error}
          </p>
        ) : null}

        <div className="mt-5 flex flex-col gap-2">
          <Button type="button" onClick={onConfirm} disabled={busy}>
            {busy ? "Turning on…" : "Turn on encryption"}
          </Button>
          <Button type="button" variant="ghost" onClick={onCancel} disabled={busy}>
            Cancel
          </Button>
        </div>
      </div>
    </div>
  );
}
