"use client";

import { useEffect, useState } from "react";
import { Check, Copy, ExternalLink, X } from "lucide-react";
import { QRCodeSVG } from "qrcode.react";
import { Card } from "@/components";
import type { UserProfile } from "@/lib/api";
import { upiPayLink } from "@/lib/upi";

export type PayViaUpiModalProps = {
  profile: UserProfile;
  onClose: () => void;
};

/**
 * "Pay via UPI" for someone else's profile: their server-generated QR (or a locally-rendered one
 * from their UPI id if the image hasn't been presigned), the id itself with copy-to-clipboard, and a
 * `upi://` link that opens the viewer's payment app on mobile.
 */
export function PayViaUpiModal({ profile, onClose }: PayViaUpiModalProps) {
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape") onClose();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  // Clear the "Copied" flag on a timer, not on the next render.
  useEffect(() => {
    if (!copied) return;
    const handle = window.setTimeout(() => setCopied(false), 1800);
    return () => window.clearTimeout(handle);
  }, [copied]);

  const upiId = profile.upi_id?.trim() ?? "";
  const payLink = upiPayLink(upiId, profile.payment_name);
  const name = profile.payment_name?.trim() || profile.display_name?.trim() || "this person";

  async function copy() {
    try {
      await navigator.clipboard.writeText(upiId);
      setCopied(true);
    } catch {
      // Clipboard can be blocked; the id is on screen to copy by hand.
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm animate-fade-in">
      <button type="button" aria-label="Close" onClick={onClose} className="absolute inset-0" />
      <Card className="relative w-full max-w-xs p-5 text-center animate-scale-in">
        <button
          type="button"
          onClick={onClose}
          aria-label="Close"
          className="absolute right-3 top-3 rounded-lg p-1.5 text-muted transition-colors hover:bg-elevated hover:text-fg"
        >
          <X className="h-4 w-4" aria-hidden />
        </button>

        <h2 className="text-sm font-semibold text-fg">Pay {name}</h2>
        <p className="mt-0.5 text-[11px] text-faint">Scan with any UPI app</p>

        <div className="mt-4 flex justify-center">
          {profile.upi_qr_url ? (
            // The server-generated PNG carries the payee's full merchant params; prefer it.
            // eslint-disable-next-line @next/next/no-img-element -- presigned, server-generated
            <img
              src={profile.upi_qr_url}
              alt={`UPI QR for ${name}`}
              className="h-52 w-52 rounded-xl border border-border bg-white p-2"
            />
          ) : (
            <span className="rounded-xl border border-border bg-white p-3">
              <QRCodeSVG value={payLink} size={184} fgColor="#1a1a2e" bgColor="#ffffff" />
            </span>
          )}
        </div>

        <button
          type="button"
          onClick={() => void copy()}
          className="mt-4 flex w-full items-center justify-center gap-2 rounded-xl border border-border bg-elevated px-3 py-2.5 text-sm text-fg transition-colors hover:bg-surface"
        >
          <span className="min-w-0 truncate font-medium">{upiId}</span>
          {copied ? (
            <Check className="h-4 w-4 shrink-0 text-brand" aria-hidden />
          ) : (
            <Copy className="h-4 w-4 shrink-0 text-muted" aria-hidden />
          )}
          <span className="sr-only">{copied ? "Copied" : "Copy UPI ID"}</span>
        </button>

        <a
          href={payLink}
          className="accent-gradient mt-2 flex w-full items-center justify-center gap-2 rounded-xl px-3 py-2.5 text-sm font-medium text-white shadow-accent-glow transition-transform active:scale-95"
        >
          <ExternalLink className="h-4 w-4" aria-hidden />
          Open payment app
        </a>
      </Card>
    </div>
  );
}
