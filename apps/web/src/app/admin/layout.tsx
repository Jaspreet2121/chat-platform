"use client";

import { ReactNode, useEffect, useRef, useState } from "react";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import {
  Activity,
  ArrowLeft,
  BarChart3,
  LayoutDashboard,
  Loader2,
  ShieldAlert
} from "lucide-react";
import { getCurrentSession } from "@/lib/api";
import { hasAccessToken } from "@/lib/session";
import { cn } from "@/lib/cn";

const nav = [
  { href: "/admin", label: "Dashboard", icon: LayoutDashboard, exact: true },
  { href: "/admin/analytics", label: "Analytics", icon: BarChart3, exact: false },
  { href: "/admin/moderation", label: "Moderation", icon: ShieldAlert, exact: false },
  { href: "/admin/health", label: "Health", icon: Activity, exact: false }
];

// Explicit gate state machine. We only ever leave "loading" AFTER getCurrentSession resolves, so a
// not-yet-loaded session is never treated as "not admin". Redirects happen only in the terminal
// non-authorized states.
type GateStatus = "loading" | "authorized" | "forbidden" | "unauthenticated";

export default function AdminLayout({ children }: { children: ReactNode }) {
  const router = useRouter();
  const pathname = usePathname();
  const [status, setStatus] = useState<GateStatus>("loading");
  // One-shot redirect guard (the /chat<->/login ping-pong lesson): never replaceState in a loop.
  const redirectedRef = useRef(false);

  // Resolve the session, THEN decide. Never redirects — only sets the terminal status.
  useEffect(() => {
    let active = true;

    async function check() {
      if (!hasAccessToken()) {
        if (active) setStatus("unauthenticated");
        return;
      }
      try {
        const session = await getCurrentSession();
        if (!active) return;
        setStatus(session.is_admin === true ? "authorized" : "forbidden");
      } catch {
        // Missing/expired/invalid session → bounce to login (not /chat).
        if (active) setStatus("unauthenticated");
      }
    }

    void check();
    return () => {
      active = false;
    };
  }, []);

  // Redirect ONLY once a terminal, non-authorized status is reached — never while still loading.
  useEffect(() => {
    if (status === "loading" || status === "authorized") return;
    if (redirectedRef.current) return;
    redirectedRef.current = true;
    router.replace(status === "forbidden" ? "/chat" : "/login");
  }, [status, router]);

  if (status !== "authorized") {
    return (
      <div className="flex min-h-screen items-center justify-center text-muted">
        <Loader2 className="mr-2 h-5 w-5 animate-spin" aria-hidden />
        {status === "loading" ? "Checking admin access…" : "Redirecting…"}
      </div>
    );
  }

  return (
    <div className="flex min-h-screen bg-bg">
      <aside className="hidden w-60 shrink-0 flex-col border-r border-border bg-surface md:flex">
        <div className="flex items-center gap-2 border-b border-border px-5 py-4">
          <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-brand">
            <ShieldAlert className="h-4 w-4 text-white" aria-hidden />
          </div>
          <span className="text-sm font-semibold text-fg">Admin</span>
        </div>

        <nav className="flex-1 space-y-1 p-3">
          {nav.map((item) => {
            const active = item.exact ? pathname === item.href : pathname.startsWith(item.href);
            const Icon = item.icon;
            return (
              <Link
                key={item.href}
                href={item.href}
                className={cn(
                  "flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition-colors",
                  active ? "bg-brand-subtle/60 text-fg ring-1 ring-brand/40" : "text-muted hover:bg-elevated hover:text-fg"
                )}
              >
                <Icon className="h-4 w-4" aria-hidden />
                {item.label}
              </Link>
            );
          })}
        </nav>

        <div className="border-t border-border p-3">
          <Link
            href="/chat"
            className="flex items-center gap-2 rounded-lg px-3 py-2 text-sm text-muted transition-colors hover:bg-elevated hover:text-fg"
          >
            <ArrowLeft className="h-4 w-4" aria-hidden />
            Back to chat
          </Link>
        </div>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex items-center justify-between border-b border-border bg-surface/60 px-5 py-3 backdrop-blur">
          <h1 className="text-sm font-semibold text-fg">Admin Console</h1>
          <Link href="/chat" className="text-xs text-muted transition-colors hover:text-fg md:hidden">
            Back to chat
          </Link>
        </header>
        <main className="flex-1 overflow-y-auto p-5 sm:p-8">{children}</main>
      </div>
    </div>
  );
}
