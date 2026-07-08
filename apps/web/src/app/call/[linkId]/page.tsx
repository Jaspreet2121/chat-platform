"use client";

import { useEffect, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { Loader2, Phone, Video } from "lucide-react";
import { hasAccessToken } from "@/lib/session";
import { getCallLink, joinCallLink, type CallLink } from "@/lib/api";
import { Button } from "@/components";

// Call-link (L2) join landing: /call/<linkId>. Registered users only — no session → /login?redirect back
// here. Reads the link's metadata, shows a small "Join call" screen, then joins: /call-links/:id/join hands
// back { call_id, room, type }, which we stash and forward to /chat where the CallProvider connects to the
// room (a conversation-less group grid). Approval (require_approval) is L3 — L2 lets everyone in.
export default function CallLinkJoinPage() {
  const router = useRouter();
  const params = useParams<{ linkId: string }>();
  const linkId = typeof params?.linkId === "string" ? params.linkId : "";

  const [phase, setPhase] = useState<"loading" | "ready" | "inactive" | "joining">("loading");
  const [link, setLink] = useState<CallLink | null>(null);
  const [error, setError] = useState("");

  useEffect(() => {
    if (!linkId) return;
    if (!hasAccessToken()) {
      router.replace(`/login?redirect=${encodeURIComponent(`/call/${linkId}`)}`);
      return;
    }
    let active = true;
    getCallLink(linkId)
      .then((l) => {
        if (!active) return;
        setLink(l);
        setPhase(l.active ? "ready" : "inactive");
      })
      .catch(() => active && setPhase("inactive"));
    return () => {
      active = false;
    };
  }, [linkId, router]);

  async function handleJoin() {
    setPhase("joining");
    setError("");
    try {
      const res = await joinCallLink(linkId);
      sessionStorage.setItem(
        "pendingLinkCall",
        JSON.stringify({ callId: res.call_id, room: res.room, type: res.type })
      );
      router.replace("/chat");
    } catch (e) {
      setError(e instanceof Error ? e.message : "Couldn't join the call.");
      setPhase("ready");
    }
  }

  const isVideo = link?.type === "video";
  const TypeIcon = isVideo ? Video : Phone;

  return (
    <main className="flex min-h-dvh items-center justify-center bg-surface px-6">
      {phase === "loading" ? (
        <div className="flex items-center gap-2 text-muted">
          <Loader2 className="h-5 w-5 animate-spin" aria-hidden />
          <p className="text-sm">Loading the call…</p>
        </div>
      ) : phase === "inactive" ? (
        <div className="flex max-w-sm flex-col items-center gap-3 text-center">
          <div className="flex h-16 w-16 items-center justify-center rounded-3xl bg-elevated">
            <Phone className="h-7 w-7 text-faint" aria-hidden />
          </div>
          <h1 className="text-lg font-semibold tracking-[-0.02em] text-fg">
            This call link is no longer active
          </h1>
          <p className="text-sm text-muted">Ask whoever shared it for a new link.</p>
          <Button variant="ghost" onClick={() => router.replace("/chat")}>
            Go to Growblic
          </Button>
        </div>
      ) : (
        <div className="flex w-full max-w-sm flex-col items-center gap-4 text-center">
          <div className="accent-gradient flex h-16 w-16 items-center justify-center rounded-3xl shadow-accent-glow">
            <TypeIcon className="h-7 w-7 text-white" aria-hidden />
          </div>
          <div>
            <h1 className="text-lg font-semibold tracking-[-0.02em] text-fg">
              {isVideo ? "Video call" : "Voice call"}
            </h1>
            <p className="mt-1 text-sm text-muted">You&apos;ve been invited to join this call.</p>
          </div>
          {error ? <p className="text-xs text-danger">{error}</p> : null}
          <Button className="w-full" isLoading={phase === "joining"} onClick={() => void handleJoin()}>
            {phase === "joining" ? "Joining…" : "Join call"}
          </Button>
        </div>
      )}
    </main>
  );
}
