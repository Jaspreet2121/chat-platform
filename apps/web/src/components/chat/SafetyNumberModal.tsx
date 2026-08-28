"use client";

import { useEffect, useState } from "react";
import { QRCodeSVG } from "qrcode.react";
import { ShieldCheck, X } from "lucide-react";
import { Button } from "@/components";
import { fetchUserKeys } from "@/lib/api";
import { publicKeysBase64 } from "@/lib/e2ee/identity";
import { safetyNumber } from "@/lib/e2ee/safetyNumber";
import { sodiumReady } from "@/lib/e2ee/sodium";

export type SafetyNumberModalProps = {
  peerUserId: string;
  peerName: string;
  onClose: () => void;
};

/** Display-only (v1): the deterministic shared code both users compute + a QR of it. */
export function SafetyNumberModal({ peerUserId, peerName, onClose }: SafetyNumberModalProps) {
  const [code, setCode] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    async function derive() {
      try {
        const sodium = await sodiumReady();
        const mine = await publicKeysBase64();
        const myFingerprint = sodium.to_hex(
          await crypto.subtle
            .digest("SHA-256", sodium.from_base64(mine.ed25519, sodium.base64_variants.ORIGINAL))
            .then((d) => new Uint8Array(d))
        );

        const peers = await fetchUserKeys([peerUserId]);
        const peerDevice = peers.find((u) => u.user_id === peerUserId)?.devices?.[0];
        if (!peerDevice) {
          if (!cancelled) setError("Your contact hasn't opened Growblic on a device yet.");
          return;
        }

        const number = await safetyNumber(myFingerprint, peerDevice.key_fingerprint);
        if (!cancelled) setCode(number);
      } catch {
        if (!cancelled) setError("Couldn't compute the safety number right now.");
      }
    }

    void derive();
    return () => {
      cancelled = true;
    };
  }, [peerUserId]);

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-6 backdrop-blur-sm"
      role="dialog"
      aria-modal="true"
      aria-label="Safety number"
    >
      <div className="w-full max-w-xs rounded-3xl bg-surface p-6 text-center shadow-elevated">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2 text-brand-hover">
            <ShieldCheck className="h-5 w-5" aria-hidden />
            <span className="text-sm font-semibold">Safety number</span>
          </div>
          <button
            type="button"
            aria-label="Close"
            onClick={onClose}
            className="rounded-lg p-1 text-muted hover:bg-elevated hover:text-fg"
          >
            <X className="h-4 w-4" aria-hidden />
          </button>
        </div>

        {code ? (
          <>
            <div className="mx-auto mt-4 w-fit rounded-xl bg-white p-3">
              <QRCodeSVG value={code.replace(/ /g, "")} size={148} />
            </div>
            <p className="mt-4 font-mono text-sm leading-relaxed tracking-wide text-fg">{code}</p>
            <p className="mt-3 text-xs text-muted">
              Compare this with {peerName}&apos;s screen. If the numbers match, no one is intercepting
              your messages.
            </p>
          </>
        ) : error ? (
          <p className="mt-6 text-sm text-muted">{error}</p>
        ) : (
          <p className="mt-6 text-sm text-muted">Computing…</p>
        )}

        <Button type="button" variant="ghost" onClick={onClose} className="mt-4 w-full">
          Done
        </Button>
      </div>
    </div>
  );
}
