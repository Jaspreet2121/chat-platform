"use client";

import { ReactNode, useEffect, useRef, useState } from "react";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import {
  Boxes,
  Activity,
  BarChart3,
  LayoutDashboard,
  Loader2,
  LogOut,
  MessagesSquare,
  ShieldAlert,
  ShieldCheck,
  Webhook
} from "lucide-react";
import { getCurrentSession } from "@/lib/api";
import { clearSessionTokens, hasAccessToken } from "@/lib/session";
import { cn } from "@/lib/cn";

const LOGIN_ROUTE = "/admin/login";

// `perm`, when set, gates the entry on the session having that permission (IAM Phase 1). Role management
// requires roles.manage (root only); Content is visible to any admin role (backend masks non-content.read).
const nav: { href: string; label: string; icon: typeof Activity; exact: boolean; perm?: string }[] = [
  { href: "/admin", label: "Dashboard", icon: LayoutDashboard, exact: true },
  { href: "/admin/analytics", label: "Analytics", icon: BarChart3, exact: false },
  { href: "/admin/moderation", label: "Moderation", icon: ShieldAlert, exact: false },
  { href: "/admin/roles", label: "Roles", icon: ShieldCheck, exact: false, perm: "roles.manage" },
  { href: "/admin/content", label: "Content", icon: MessagesSquare, exact: false },
  // Surface-3 platform ops. apps.view / webhooks.view = root+admin+support (read-only support by IAM
  // design); moderator sees neither. Mutations (re-enqueue) are separately webhooks.manage server-side.
  { href: "/admin/apps", label: "Apps", icon: Boxes, exact: false, perm: "apps.view" },
  { href: "/admin/webhooks", label: "Webhooks", icon: Webhook, exact: false, perm: "webhooks.view" },
  { href: "/admin/health", label: "Health", icon: Activity, exact: false }
];

// Explicit gate state machine. We only leave "loading" AFTER getCurrentSession resolves, so a
// not-yet-loaded session is never treated as "not admin". Redirects fire only in terminal
// non-authorized states, and always to the self-contained /admin/login (never the chat app).
type GateStatus = "loading" | "authorized" | "forbidden" | "unauthenticated";

export default function AdminLayout({ children }: { children: ReactNode }) {
  const router = useRouter();
  const pathname = usePathname();
  // /admin/login is the ONE ungated route inside this group — otherwise the login page would require
  // admin to view it (infinite loop). The gate skips it entirely and renders it standalone.
  const isLoginRoute = pathname === LOGIN_ROUTE;
  const [status, setStatus] = useState<GateStatus>("loading");
  // The session's IAM permissions, used to gate nav entries (e.g. Roles → roles.manage).
  const [permissions, setPermissions] = useState<string[]>([]);
  const redirectedRef = useRef(false);

  // Resolve the session and set a terminal status. Re-runs when entering/leaving the login route
  // (the layout stays mounted across /admin/login → /admin, so this is what re-checks after login).
  useEffect(() => {
    if (isLoginRoute) {
      redirectedRef.current = false;
      setStatus("loading");
      return;
    }

    let active = true;
    setStatus("loading");

    async function check() {
      if (!hasAccessToken()) {
        if (active) setStatus("unauthenticated");
        return;
      }
      try {
        const session = await getCurrentSession();
        if (!active) return;
        setPermissions(session.permissions ?? []);
        setStatus(session.is_admin === true ? "authorized" : "forbidden");
      } catch {
        if (active) setStatus("unauthenticated");
      }
    }

    void check();
    return () => {
      active = false;
    };
  }, [isLoginRoute]);

  // Redirect only once a terminal, non-authorized status is reached — always to /admin/login.
  useEffect(() => {
    if (isLoginRoute) return;
    if (status === "loading" || status === "authorized") return;
    if (redirectedRef.current) return;
    redirectedRef.current = true;
    // forbidden = authenticated but not an admin → show access-denied on the admin login.
    router.replace(status === "forbidden" ? `${LOGIN_ROUTE}?denied=1` : LOGIN_ROUTE);
  }, [status, isLoginRoute, router]);

  function handleLogout() {
    clearSessionTokens();
    router.replace(LOGIN_ROUTE);
  }

  // The login page renders ungated, standalone (no sidebar/gate).
  if (isLoginRoute) {
    return <>{children}</>;
  }

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
          <span className="text-sm font-semibold text-fg">Admin Console</span>
        </div>

        <nav className="flex-1 space-y-1 p-3">
          {nav
            .filter((item) => !item.perm || permissions.includes(item.perm))
            .map((item) => {
            const active = item.exact ? pathname === item.href : pathname.startsWith(item.href);
            const Icon = item.icon;
            return (
              <Link
                key={item.href}
                href={item.href}
                className={cn(
                  "flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition-colors",
                  active
                    ? "bg-brand-subtle/60 text-fg ring-1 ring-brand/40"
                    : "text-muted hover:bg-elevated hover:text-fg"
                )}
              >
                <Icon className="h-4 w-4" aria-hidden />
                {item.label}
              </Link>
            );
          })}
        </nav>

        <div className="border-t border-border p-3">
          <button
            type="button"
            onClick={handleLogout}
            className="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-sm text-muted transition-colors hover:bg-danger/10 hover:text-danger"
          >
            <LogOut className="h-4 w-4" aria-hidden />
            Log out
          </button>
        </div>
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex items-center justify-between border-b border-border bg-surface/60 px-5 py-3 backdrop-blur">
          <h1 className="text-sm font-semibold text-fg">Admin Console</h1>
          <button
            type="button"
            onClick={handleLogout}
            className="flex items-center gap-1.5 text-xs text-muted transition-colors hover:text-danger md:hidden"
          >
            <LogOut className="h-4 w-4" aria-hidden />
            Log out
          </button>
        </header>
        <main className="flex-1 overflow-y-auto p-5 sm:p-8">{children}</main>
      </div>
    </div>
  );
}
