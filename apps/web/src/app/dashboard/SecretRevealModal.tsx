"use client";

import { useState } from "react";
import { Check, Copy, TriangleAlert, X } from "lucide-react";

/**
 * Shows a plaintext secret (an API key's `api_key`, or a webhook's `signing_secret`) EXACTLY ONCE.
 *
 * SECURITY: the caller holds the secret in state only while this modal is mounted and clears it on close, so
 * it never lives longer than the modal. This component never logs it and never persists it anywhere; the
 * only sinks are the read-only field and an explicit copy-to-clipboard.
 */
export function SecretRevealModal({
  title,
  secret,
  note,
  onClose
}: {
  title: string;
  secret: string;
  note: string;
  onClose: () => void;
}) {
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(secret);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      // Clipboard blocked (e.g. non-secure context) — the value is still selectable in the field.
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
      <div className="w-full max-w-lg rounded-xl border border-border bg-surface p-5 shadow-xl">
        <div className="mb-3 flex items-center justify-between">
          <h2 className="text-sm font-semibold text-fg">{title}</h2>
          <button type="button" onClick={onClose} aria-label="Close" className="text-muted hover:text-fg">
            <X className="h-4 w-4" aria-hidden />
          </button>
        </div>

        <div className="mb-3 flex items-start gap-2 rounded-lg bg-danger/10 p-3 text-xs text-danger">
          <TriangleAlert className="mt-0.5 h-4 w-4 shrink-0" aria-hidden />
          <span>Copy this now — you won&rsquo;t be able to see it again.</span>
        </div>

        <div className="flex items-center gap-2">
          <input
            readOnly
            value={secret}
            onFocus={(e) => e.currentTarget.select()}
            className="min-w-0 flex-1 rounded-lg border border-border bg-elevated px-3 py-2 font-mono text-xs text-fg"
          />
          <button
            type="button"
            onClick={() => void copy()}
            className="flex shrink-0 items-center gap-1.5 rounded-lg bg-brand px-3 py-2 text-xs font-medium text-white transition-colors hover:bg-brand-hover"
          >
            {copied ? (
              <>
                <Check className="h-3.5 w-3.5" aria-hidden /> Copied
              </>
            ) : (
              <>
                <Copy className="h-3.5 w-3.5" aria-hidden /> Copy
              </>
            )}
          </button>
        </div>

        <p className="mt-3 text-xs text-muted">{note}</p>

        <div className="mt-4 flex justify-end">
          <button
            type="button"
            onClick={onClose}
            className="rounded-lg border border-border px-3 py-1.5 text-xs text-fg transition-colors hover:bg-elevated"
          >
            Done
          </button>
        </div>
      </div>
    </div>
  );
}
