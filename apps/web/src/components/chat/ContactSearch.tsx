"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { Check, Copy, Loader2, MessageCircle, MessageSquarePlus, Search, X } from "lucide-react";
import { type CountryCode } from "libphonenumber-js";
import { DEFAULT_COUNTRY } from "@/lib/countries";
import { formatSearchInput, toE164Loose } from "@/lib/phone";
import { createInvite, findUserByPhone, type UserProfile } from "@/lib/api";
import { Avatar, Button } from "@/components";
import { cn } from "@/lib/cn";

const DEBOUNCE_MS = 350;

export type ContactSearchProps = {
  /** Start (create) a 1:1 direct chat with the resolved peer. Awaited so we can show a spinner + reset. */
  onStartDirectChat: (profile: UserProfile) => void | Promise<void>;
  /** Bump to focus the number input (the rail/tab-bar "Invite" entry lands here). */
  focusNonce?: number;
};

type Lookup =
  | { kind: "idle" }
  | { kind: "loading" }
  | { kind: "found"; profile: UserProfile }
  | { kind: "empty" }
  | { kind: "self" }
  | { kind: "error"; message: string };

function shortId(id: string): string {
  return `#${id.slice(0, 8)}`;
}

// --- WhatsApp-style invite (number not on the platform) --------------------------------------------
// Mints an invite code once (cached per searched number), then opens WhatsApp / the SMS app with the
// recipient AND a pre-filled join message via device URL schemes — the user just hits Send. No
// WhatsApp/SMS API involved.

function inviteMessage(code: string): string {
  return `Hey! Join me on Growblic: ${window.location.origin}/invite/${code}`;
}

// iOS wants `sms:<number>&body=`, everything else `sms:<number>?body=`.
function smsHref(e164: string, message: string): string {
  const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent);
  return `sms:${e164}${isIOS ? "&" : "?"}body=${encodeURIComponent(message)}`;
}

function waHref(e164: string, message: string): string {
  return `https://wa.me/${e164.replace(/\D/g, "")}?text=${encodeURIComponent(message)}`;
}

function InviteActions({ e164 }: { e164: string }) {
  const [code, setCode] = useState<string | null>(null);
  const [busy, setBusy] = useState<"whatsapp" | "sms" | "copy" | null>(null);
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState("");

  // The invite code is stable per (you, number) — mint once, reuse for all three actions.
  async function ensureCode(): Promise<string> {
    if (code) return code;
    const invite = await createInvite(e164);
    setCode(invite.invite_code);
    return invite.invite_code;
  }

  async function act(kind: "whatsapp" | "sms" | "copy") {
    setBusy(kind);
    setError("");
    try {
      const message = inviteMessage(await ensureCode());
      if (kind === "whatsapp") {
        window.open(waHref(e164, message), "_blank", "noopener,noreferrer");
      } else if (kind === "sms") {
        window.location.href = smsHref(e164, message);
      } else {
        await navigator.clipboard.writeText(message);
        setCopied(true);
        setTimeout(() => setCopied(false), 2000);
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not create the invite.");
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="mt-2 rounded-xl border border-border/60 bg-elevated/50 p-2.5 animate-fade-in">
      <p className="mb-2 px-0.5 text-xs text-muted">
        This number isn&apos;t on Growblic yet — invite them:
      </p>
      <div className="flex flex-wrap gap-1.5">
        <Button
          size="sm"
          onClick={() => act("whatsapp")}
          isLoading={busy === "whatsapp"}
          leftIcon={<MessageCircle className="h-4 w-4" aria-hidden />}
        >
          Invite on WhatsApp
        </Button>
        <Button
          size="sm"
          variant="ghost"
          onClick={() => act("sms")}
          isLoading={busy === "sms"}
          leftIcon={<MessageSquarePlus className="h-4 w-4" aria-hidden />}
        >
          Invite via SMS
        </Button>
        <Button
          size="sm"
          variant="ghost"
          onClick={() => act("copy")}
          isLoading={busy === "copy"}
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
      </div>
      {error ? <p className="mt-1.5 px-0.5 text-xs text-danger">{error}</p> : null}
    </div>
  );
}

// PRIMARY sidebar search: find someone by PHONE NUMBER (WhatsApp-style) and start a direct chat.
// NO country dropdown here (that belongs to login/account creation): the number is normalized
// silently — a bare national number gets the default region (+91), and a full "+<cc>…" international
// number parses as typed — producing the SAME E.164 the backend stores → lookup_active_by_phone
// matches. Debounced; clean idle/loading/no-result/self/error states.
const SEARCH_ISO = DEFAULT_COUNTRY.iso2 as CountryCode;

export function ContactSearch({ onStartDirectChat, focusNonce }: ContactSearchProps) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [localNumber, setLocalNumber] = useState("");
  const [state, setState] = useState<Lookup>({ kind: "idle" });
  const [isStarting, setIsStarting] = useState(false);

  // Invite entry: focus the input so the user types the number to invite.
  useEffect(() => {
    if (focusNonce) inputRef.current?.focus();
  }, [focusNonce]);

  const e164 = useMemo(() => toE164Loose(localNumber, SEARCH_ISO), [localNumber]);
  const hasDigits = localNumber.replace(/\D/g, "").length > 0;
  const showIncompleteHint = hasDigits && e164 === "" && state.kind === "idle";

  // Debounced lookup whenever a VALID E.164 is present. All setState runs in deferred callbacks
  // (timer / promise), never synchronously in the effect body — avoids cascading renders.
  useEffect(() => {
    let cancelled = false;

    if (!e164) {
      const reset = setTimeout(() => {
        if (!cancelled) setState({ kind: "idle" });
      }, 0);
      return () => {
        cancelled = true;
        clearTimeout(reset);
      };
    }

    const handle = setTimeout(() => {
      setState({ kind: "loading" });
      findUserByPhone(e164)
        .then((profile) => {
          if (!cancelled) setState({ kind: "found", profile });
        })
        .catch((error) => {
          if (cancelled) return;
          const message = error instanceof Error ? error.message : "Lookup failed.";
          if (/no account/i.test(message)) setState({ kind: "empty" });
          else if (/yourself/i.test(message)) setState({ kind: "self" });
          else setState({ kind: "error", message });
        });
    }, DEBOUNCE_MS);

    return () => {
      cancelled = true;
      clearTimeout(handle);
    };
  }, [e164]);

  function handleLocal(raw: string) {
    setLocalNumber(formatSearchInput(raw, SEARCH_ISO));
  }

  function clear() {
    setLocalNumber("");
  }

  async function handleMessage(profile: UserProfile) {
    setIsStarting(true);
    try {
      await onStartDirectChat(profile);
      setLocalNumber("");
    } finally {
      setIsStarting(false);
    }
  }

  return (
    <div className="border-b border-border/60 px-3 py-2.5">
      <div className="flex gap-1.5">
        <div className="relative min-w-0 flex-1">
          <Search
            className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-faint"
            aria-hidden
          />
          <input
            ref={inputRef}
            inputMode="tel"
            autoComplete="off"
            placeholder="Search by phone number"
            value={localNumber}
            onChange={(event) => handleLocal(event.target.value)}
            aria-label="Search by phone number"
            className={cn(
              "h-11 w-full rounded-xl border border-border/70 bg-elevated/50 pl-9 pr-9 text-sm text-fg",
              "placeholder:text-faint outline-none transition-colors duration-150",
              "focus:border-brand/50 focus:bg-elevated focus:ring-1 focus:ring-brand-ring"
            )}
          />
          {state.kind === "loading" ? (
            <Loader2
              className="absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 animate-spin text-brand-hover"
              aria-hidden
            />
          ) : hasDigits ? (
            <button
              type="button"
              onClick={clear}
              aria-label="Clear"
              className="absolute right-2 top-1/2 -translate-y-1/2 rounded-md p-1 text-faint transition-colors hover:text-fg"
            >
              <X className="h-4 w-4" aria-hidden />
            </button>
          ) : null}
        </div>
      </div>

      {/* Result / status area */}
      {state.kind === "found" ? (
        <div className="mt-2 flex items-center gap-2.5 rounded-xl border border-border/60 bg-elevated/50 p-2 transition-colors hover:bg-elevated animate-fade-in">
          <Avatar
            id={state.profile.user_id}
            name={state.profile.display_name ?? undefined}
            imageUrl={state.profile.avatar_url}
            size="sm"
          />
          <div className="min-w-0 flex-1">
            <p className="truncate text-sm text-fg">
              {state.profile.display_name || "Unnamed profile"}
            </p>
            <p className="truncate text-xs text-faint">{shortId(state.profile.user_id)}</p>
          </div>
          <Button
            size="sm"
            onClick={() => handleMessage(state.profile)}
            isLoading={isStarting}
            leftIcon={<MessageSquarePlus className="h-4 w-4" aria-hidden />}
            className="shrink-0"
          >
            Message
          </Button>
        </div>
      ) : state.kind === "empty" ? (
        <InviteActions key={e164} e164={e164} />
      ) : state.kind === "self" ? (
        <p className="mt-2 px-1 text-xs text-muted animate-fade-in">
          That&apos;s your own number.
        </p>
      ) : state.kind === "error" ? (
        <p className="mt-2 px-1 text-xs text-danger animate-fade-in">{state.message}</p>
      ) : showIncompleteHint ? (
        <p className="mt-2 px-1 text-xs text-faint">
          Keep typing — a full {DEFAULT_COUNTRY.name} mobile number, or +country code for others.
        </p>
      ) : null}
    </div>
  );
}
