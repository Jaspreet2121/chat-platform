"use client";

import { useState } from "react";
import { Check, Copy, Link2, Phone, Share2, Video, X } from "lucide-react";
import { createCallLink } from "@/lib/api";
import { Button } from "@/components";
import { cn } from "@/lib/cn";

export type NewCallLinkModalProps = {
  onClose: () => void;
};

type CallLinkType = "voice" | "video";

/**
 * "New call link" — generate a reusable, shareable call link. Pick voice/video + whether joining needs
 * approval (stored now; enforced in L3), create it, then copy/share the `/call/<id>` URL. Bottom sheet on
 * mobile, centered modal on desktop (mirrors AddParticipantsSheet).
 */
export function NewCallLinkModal({ onClose }: NewCallLinkModalProps) {
  const [type, setType] = useState<CallLinkType>("video");
  const [requireApproval, setRequireApproval] = useState(false);
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState("");
  const [url, setUrl] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  async function handleCreate() {
    setCreating(true);
    setError("");
    try {
      const link = await createCallLink({ type, require_approval: requireApproval });
      setUrl(`${window.location.origin}/call/${link.id}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Couldn't create the link.");
    } finally {
      setCreating(false);
    }
  }

  async function handleCopy() {
    if (!url) return;
    try {
      await navigator.clipboard.writeText(url);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      /* clipboard blocked — the field is selectable as a fallback */
    }
  }

  async function handleShare() {
    if (!url) return;
    if (typeof navigator !== "undefined" && "share" in navigator) {
      try {
        await navigator.share({ title: "Join my call", url });
        return;
      } catch {
        /* user cancelled / unsupported — fall through to copy */
      }
    }
    void handleCopy();
  }

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="New call link"
      className="fixed inset-0 z-[70] flex items-end justify-center sm:items-center"
    >
      <button
        type="button"
        aria-label="Close"
        onClick={onClose}
        className="absolute inset-0 bg-black/50 backdrop-blur-sm animate-fade-in"
      />

      <div className="relative flex w-full flex-col rounded-t-2xl border border-border bg-surface shadow-xl animate-slide-up sm:m-4 sm:max-w-md sm:rounded-2xl">
        {/* Header */}
        <div className="flex items-center gap-3 border-b border-border px-4 py-3">
          <Link2 className="h-5 w-5 shrink-0 text-brand-hover" aria-hidden />
          <h2 className="min-w-0 flex-1 text-sm font-semibold text-fg">New call link</h2>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close"
            className="rounded-md p-1 text-faint transition-colors hover:text-fg"
          >
            <X className="h-5 w-5" aria-hidden />
          </button>
        </div>

        <div className="flex flex-col gap-4 px-4 py-4">
          {url ? (
            <>
              <p className="text-sm text-muted">
                Anyone with this link can join the call. Share it:
              </p>
              <div className="flex items-center gap-2 rounded-xl border border-border/70 bg-elevated/50 px-3 py-2">
                <Link2 className="h-4 w-4 shrink-0 text-faint" aria-hidden />
                <input
                  readOnly
                  value={url}
                  onFocus={(e) => e.currentTarget.select()}
                  aria-label="Call link URL"
                  className="min-w-0 flex-1 truncate bg-transparent text-sm text-fg outline-none"
                />
              </div>
              <div className="flex gap-2">
                <Button
                  onClick={handleCopy}
                  className="flex-1"
                  leftIcon={
                    copied ? (
                      <Check className="h-4 w-4 text-success" aria-hidden />
                    ) : (
                      <Copy className="h-4 w-4" aria-hidden />
                    )
                  }
                >
                  {copied ? "Copied" : "Copy link"}
                </Button>
                <Button
                  variant="ghost"
                  onClick={handleShare}
                  leftIcon={<Share2 className="h-4 w-4" aria-hidden />}
                >
                  Share
                </Button>
              </div>
            </>
          ) : (
            <>
              {/* Call type */}
              <div>
                <span className="mb-2 block text-xs font-medium uppercase tracking-wide text-faint">
                  Call type
                </span>
                <div className="flex gap-2">
                  <TypeButton active={type === "video"} onClick={() => setType("video")}>
                    <Video className="h-4 w-4" aria-hidden /> Video
                  </TypeButton>
                  <TypeButton active={type === "voice"} onClick={() => setType("voice")}>
                    <Phone className="h-4 w-4" aria-hidden /> Voice
                  </TypeButton>
                </div>
              </div>

              {/* Require approval */}
              <button
                type="button"
                onClick={() => setRequireApproval((v) => !v)}
                className="flex min-h-11 w-full items-center gap-3 text-left"
              >
                <span className="min-w-0 flex-1">
                  <span className="block text-sm text-fg">Require approval to join</span>
                  <span className="block text-xs text-muted">
                    You&apos;ll admit people from a waiting room.
                  </span>
                </span>
                <span
                  className={cn(
                    "relative h-6 w-11 shrink-0 rounded-full transition-colors",
                    requireApproval ? "accent-gradient" : "bg-border-strong"
                  )}
                  aria-hidden
                >
                  <span
                    className={cn(
                      "absolute top-0.5 h-5 w-5 rounded-full bg-white shadow-subtle transition-all",
                      requireApproval ? "left-[22px]" : "left-0.5"
                    )}
                  />
                </span>
              </button>

              {error ? <p className="text-xs text-danger">{error}</p> : null}

              <Button
                onClick={handleCreate}
                isLoading={creating}
                leftIcon={creating ? undefined : <Link2 className="h-4 w-4" aria-hidden />}
              >
                {creating ? "Creating…" : "Create link"}
              </Button>
            </>
          )}
        </div>
      </div>
    </div>
  );
}

function TypeButton({
  active,
  onClick,
  children
}: {
  active: boolean;
  onClick: () => void;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "flex flex-1 items-center justify-center gap-1.5 rounded-lg px-3 py-2.5 text-sm font-medium transition-colors",
        active ? "bg-brand-subtle text-brand-hover ring-1 ring-brand/40" : "bg-elevated/60 text-muted hover:text-fg"
      )}
    >
      {children}
    </button>
  );
}
