"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { QrCode, RotateCcw, Smartphone } from "lucide-react";
import { QRCodeSVG } from "qrcode.react";
import { createLinkQr, pollUntilResolved, type LinkQr } from "@/lib/link";
import { hasAccessToken, setSessionId, setSessionTokens } from "@/lib/session";
import { AuthLayout, Button, Card } from "@/components";

// "Link with phone" (backend 1fb5f13): mint an anonymous link request, show its QR, long-poll until
// the phone approves, then store the minted session EXACTLY like the OTP login does and enter the
// app — nothing downstream can tell the two logins apart. link_id/poll_token live only in this
// component's state: never persisted, never in a URL, never logged; a new QR is minted per visit,
// per expiry, and on returning to a hidden tab.

const QR_TTL_SECONDS = 60;

type Status = "loading" | "showing" | "error";

export default function LinkPage() {
  const router = useRouter();
  const [status, setStatus] = useState<Status>("loading");
  const [qr, setQr] = useState<LinkQr | null>(null);
  const [remaining, setRemaining] = useState(QR_TTL_SECONDS);
  const abortRef = useRef<AbortController | null>(null);
  const hasRedirectedRef = useRef(false);
  const mintRef = useRef<() => void>(() => {});

  const goToApp = useCallback(() => {
    if (hasRedirectedRef.current) return;
    hasRedirectedRef.current = true;
    router.replace("/chat");
  }, [router]);

  // Already signed in → straight to the app (same guard as the login page).
  useEffect(() => {
    if (hasAccessToken()) goToApp();
  }, [goToApp]);

  const stopPolling = useCallback(() => {
    abortRef.current?.abort();
    abortRef.current = null;
  }, []);

  // Mint a fresh code + start its poll loop. Any previous loop is aborted first (one live QR at a
  // time; the server expires the old one on its own).
  const mint = useCallback(async () => {
    stopPolling();
    setStatus("loading");

    try {
      const created = await createLinkQr();
      setQr(created);
      setRemaining(created.expires_in ?? QR_TTL_SECONDS);
      setStatus("showing");

      const controller = new AbortController();
      abortRef.current = controller;

      const outcome = await pollUntilResolved(
        created.link_id,
        created.poll_token,
        controller.signal
      );

      if (outcome.status === "approved") {
        setSessionTokens({
          accessToken: outcome.session.access_token,
          refreshToken: outcome.session.refresh_token
        });
        // The linked session's identity: session_revoked matches on this (the device_id was minted
        // server-side and this browser never learns it as an identity).
        setSessionId(outcome.session.session_id);
        goToApp();
      } else if (outcome.status === "refresh") {
        // consumed/expired server-side → immediately mint a fresh code (via the ref: a useCallback
        // cannot list itself as a dependency).
        mintRef.current();
      }
      // "cancelled" = we aborted it ourselves (unmount / hidden / re-mint) — nothing to do.
    } catch {
      setStatus("error");
    }
  }, [goToApp, stopPolling]);

  useEffect(() => {
    mintRef.current = () => void mint();
  }, [mint]);

  // Mount: mint (deferred a tick — the hooks lint forbids synchronous state writes inside an
  // effect, and mint sets status immediately). Unmount: stop the loop.
  useEffect(() => {
    const timer = setTimeout(() => void mint(), 0);

    return () => {
      clearTimeout(timer);
      stopPolling();
    };
  }, [mint, stopPolling]);

  // The 60s countdown; at zero, auto-refresh (mint aborts the stale poll itself).
  useEffect(() => {
    if (status !== "showing") return;
    const timer = setInterval(() => setRemaining((current) => current - 1), 1_000);
    return () => clearInterval(timer);
  }, [status, qr?.link_id]);

  useEffect(() => {
    if (status !== "showing" || remaining > 0) return;
    const timer = setTimeout(() => void mint(), 0);
    return () => clearTimeout(timer);
  }, [remaining, status, mint]);

  // Tab hidden → pause (abort) the poll; visible again → a FRESH code (the old one may have expired
  // unseen, and a stale QR on screen is worse than a flicker).
  useEffect(() => {
    const onVisibility = () => {
      if (document.visibilityState === "hidden") {
        stopPolling();
      } else if (!hasRedirectedRef.current) {
        void mint();
      }
    };

    document.addEventListener("visibilitychange", onVisibility);
    return () => document.removeEventListener("visibilitychange", onVisibility);
  }, [mint, stopPolling]);

  const progress = Math.max(remaining, 0) / QR_TTL_SECONDS;

  return (
    <AuthLayout
      icon={<QrCode className="h-6 w-6" aria-hidden />}
      title="Growblic"
      tagline="Link this browser to your phone."
      footnote="The code changes every 60 seconds and works only once."
    >
      <Card className="space-y-5 p-6">
        <div className="space-y-1">
          <h1 className="font-display text-xl font-semibold text-fg">Link with phone</h1>
          <p className="text-sm text-muted">
            Open Growblic on your phone → Settings → Linked devices → Link a device → scan this code.
          </p>
        </div>

        <div className="flex flex-col items-center gap-4">
          {/* The QR sits on a forced-white tile so it stays dark-on-light in dark mode too. */}
          <div className="relative rounded-2xl bg-white p-4 shadow-sm">
            {status === "showing" && qr ? (
              <QRCodeSVG value={qr.qr_payload} size={240} fgColor="#1a1a2e" bgColor="#ffffff" />
            ) : (
              <div className="flex h-[240px] w-[240px] items-center justify-center">
                {status === "error" ? (
                  <div className="space-y-3 text-center">
                    <p className="text-sm text-muted">Code expired — refresh</p>
                    <Button variant="primary" onClick={() => void mint()}>
                      <RotateCcw className="h-4 w-4" /> New code
                    </Button>
                  </div>
                ) : (
                  <p className="text-sm text-muted">Generating code…</p>
                )}
              </div>
            )}
          </div>

          {status === "showing" ? (
            <div className="flex items-center gap-2 text-xs text-faint" aria-live="polite">
              {/* Countdown ring: a 20px circle whose stroke drains with the TTL. */}
              <svg width="20" height="20" viewBox="0 0 20 20" aria-hidden>
                <circle cx="10" cy="10" r="8" fill="none" stroke="currentColor" strokeOpacity="0.2" strokeWidth="2" />
                <circle
                  cx="10"
                  cy="10"
                  r="8"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="2"
                  strokeDasharray={2 * Math.PI * 8}
                  strokeDashoffset={2 * Math.PI * 8 * (1 - progress)}
                  transform="rotate(-90 10 10)"
                />
              </svg>
              New code in {Math.max(remaining, 0)}s
            </div>
          ) : null}
        </div>

        <div className="flex items-center justify-between border-t border-border pt-4">
          <span className="flex items-center gap-1.5 text-xs text-faint">
            <Smartphone className="h-3.5 w-3.5" aria-hidden /> Waiting for your phone…
          </span>
          <a className="text-sm font-medium text-brand hover:underline" href="/login">
            Use phone number instead
          </a>
        </div>
      </Card>
    </AuthLayout>
  );
}
