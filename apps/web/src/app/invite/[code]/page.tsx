"use client";

import { useEffect } from "react";
import { useParams, useRouter } from "next/navigation";
import { Loader2 } from "lucide-react";

// Invite deep-link landing: `/invite/<code>` (the link inside the WhatsApp/SMS invite message). V1 just
// forwards to the normal login/signup flow, carrying the code as ?invite= so acceptance can be tied back
// to the inviter later (the invites table already records who invited whom).
export default function InviteLandingPage() {
  const router = useRouter();
  const params = useParams<{ code: string }>();

  useEffect(() => {
    const code = typeof params?.code === "string" ? params.code : "";
    router.replace(code ? `/login?invite=${encodeURIComponent(code)}` : "/login");
  }, [params, router]);

  return (
    <main className="flex min-h-dvh items-center justify-center bg-surface">
      <div className="flex items-center gap-2 text-muted">
        <Loader2 className="h-5 w-5 animate-spin" aria-hidden />
        <p className="text-sm">Taking you to Growblic…</p>
      </div>
    </main>
  );
}
