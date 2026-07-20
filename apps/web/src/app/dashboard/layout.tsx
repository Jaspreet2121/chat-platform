"use client";

import { ReactNode, useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { KeyRound, Loader2, LogOut } from "lucide-react";
import { getCurrentSession } from "@/lib/api";
import { clearSessionTokens, hasAccessToken } from "@/lib/session";

// The chat login — the app owner IS a first-party chat user; there is NO separate dashboard login (mirrors
// how admin has its own login, but here we deliberately reuse the chat session/login instead).
const LOGIN_ROUTE = "/login";

// Simpler than the admin gate: the dashboard needs only a valid logged-in session (any first-party user can
// own apps). Ownership of each specific app is enforced by the backend (:not_owner → 403), so there's no
// is_admin / permission check here — just "are you logged in".
type GateStatus = "loading" | "authorized" | "unauthenticated";

export default function DashboardLayout({ children }: { children: ReactNode }) {
  const router = useRouter();
  const [status, setStatus] = useState<GateStatus>("loading");
  const redirectedRef = useRef(false);

  useEffect(() => {
    let active = true;
    async function check() {
      if (!hasAccessToken()) {
        if (active) setStatus("unauthenticated");
        return;
      }
      try {
        await getCurrentSession();
        if (active) setStatus("authorized");
      } catch {
        if (active) setStatus("unauthenticated");
      }
    }
    void check();
    return () => {
      active = false;
    };
  }, []);

  useEffect(() => {
    if (status !== "unauthenticated" || redirectedRef.current) return;
    redirectedRef.current = true;
    // Carry the destination so a dashboard deep-link round-trips through login back HERE (the login's
    // safeRedirect guard allows it — same-origin path). Logout below stays a plain /login on purpose.
    router.replace(`${LOGIN_ROUTE}?redirect=/dashboard`);
  }, [status, router]);

  function handleLogout() {
    clearSessionTokens();
    router.replace(LOGIN_ROUTE);
  }

  if (status !== "authorized") {
    return (
      <div className="flex min-h-screen items-center justify-center text-muted">
        <Loader2 className="mr-2 h-5 w-5 animate-spin" aria-hidden />
        {status === "loading" ? "Checking your session…" : "Redirecting to login…"}
      </div>
    );
  }

  return (
    <div className="flex min-h-screen flex-col bg-bg">
      <header className="flex items-center justify-between border-b border-border bg-surface px-5 py-3">
        <div className="flex items-center gap-2">
          <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-brand">
            <KeyRound className="h-4 w-4 text-white" aria-hidden />
          </div>
          <div>
            <span className="block text-sm font-semibold leading-tight text-fg">Growblic Developers</span>
            <span className="block text-[11px] leading-tight text-muted">Apps · API keys · Webhooks</span>
          </div>
        </div>
        <button
          type="button"
          onClick={handleLogout}
          className="flex items-center gap-1.5 text-xs text-muted transition-colors hover:text-danger"
        >
          <LogOut className="h-4 w-4" aria-hidden />
          Log out
        </button>
      </header>
      <main className="flex-1 overflow-y-auto p-5 sm:p-8">{children}</main>
    </div>
  );
}
