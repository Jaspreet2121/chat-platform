"use client";

import { useEffect, useMemo, useState } from "react";
import { Loader2, MessageSquarePlus, Search, X } from "lucide-react";
import { type CountryCode } from "libphonenumber-js";
import { Country, DEFAULT_COUNTRY } from "@/lib/countries";
import { formatLocal, phoneMeta, toE164 } from "@/lib/phone";
import { findUserByPhone, type UserProfile } from "@/lib/api";
import { Avatar, Button, CountryCodeSelect } from "@/components";
import { cn } from "@/lib/cn";

const DEBOUNCE_MS = 350;

export type ContactSearchProps = {
  /** Start (create) a 1:1 direct chat with the resolved peer. Awaited so we can show a spinner + reset. */
  onStartDirectChat: (profile: UserProfile) => void | Promise<void>;
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

// PRIMARY sidebar search: find someone by PHONE NUMBER (WhatsApp-style) and start a direct chat.
// Reuses the shared libphonenumber-js helpers (India +91 default, country dropdown, as-you-type +
// per-country validation) so it emits the exact E.164 the backend stores → lookup_active_by_phone
// matches. Debounced; clean idle/loading/no-result/self/error states.
export function ContactSearch({ onStartDirectChat }: ContactSearchProps) {
  const [country, setCountry] = useState<Country>(DEFAULT_COUNTRY);
  const [localNumber, setLocalNumber] = useState("");
  const [state, setState] = useState<Lookup>({ kind: "idle" });
  const [isStarting, setIsStarting] = useState(false);

  const meta = useMemo(() => phoneMeta(country.iso2 as CountryCode), [country]);
  const e164 = toE164(country.iso2 as CountryCode, localNumber);
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

  function handleCountry(next: Country) {
    setCountry(next);
    const iso = next.iso2 as CountryCode;
    setLocalNumber((current) => formatLocal(iso, current, phoneMeta(iso).maxDigits));
  }

  function handleLocal(raw: string) {
    setLocalNumber(formatLocal(country.iso2 as CountryCode, raw, meta.maxDigits));
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
    <div className="border-b border-border px-3 py-3">
      <div className="flex gap-2">
        <CountryCodeSelect value={country} onChange={handleCountry} />
        <div className="relative min-w-0 flex-1">
          <Search
            className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-faint"
            aria-hidden
          />
          <input
            inputMode="tel"
            autoComplete="off"
            placeholder="Search by phone number"
            value={localNumber}
            onChange={(event) => handleLocal(event.target.value)}
            aria-label="Search by phone number"
            className={cn(
              "h-11 w-full rounded-xl border border-border bg-elevated/70 pl-9 pr-9 text-sm text-fg",
              "placeholder:text-faint shadow-[inset_0_1px_2px_rgb(0_0_0/0.05)] outline-none",
              "transition-all duration-200 focus:border-brand focus:bg-elevated focus:ring-2",
              "focus:ring-brand-ring focus:shadow-glow-sm"
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
        <div className="mt-2.5 flex items-center gap-2.5 rounded-xl border border-border bg-elevated/80 p-2.5 shadow-subtle transition-colors hover:bg-elevated animate-bubble-in">
          <Avatar
            id={state.profile.user_id}
            name={state.profile.display_name ?? undefined}
            imageUrl={state.profile.avatar_url}
            size="sm"
          />
          <div className="min-w-0 flex-1">
            <p className="truncate text-sm font-medium text-fg">
              {state.profile.display_name || "Unnamed profile"}
            </p>
            <p className="truncate text-xs text-faint">{shortId(state.profile.user_id)}</p>
          </div>
          <Button
            size="sm"
            onClick={() => handleMessage(state.profile)}
            isLoading={isStarting}
            leftIcon={<MessageSquarePlus className="h-4 w-4" aria-hidden />}
            className="shrink-0 bg-gradient-to-r from-brand to-brand-hover shadow-glow-sm hover:opacity-90"
          >
            Message
          </Button>
        </div>
      ) : state.kind === "empty" ? (
        <p className="mt-2 px-1 text-xs text-muted animate-fade-in">
          No account uses this number.
        </p>
      ) : state.kind === "self" ? (
        <p className="mt-2 px-1 text-xs text-muted animate-fade-in">
          That&apos;s your own number.
        </p>
      ) : state.kind === "error" ? (
        <p className="mt-2 px-1 text-xs text-danger animate-fade-in">{state.message}</p>
      ) : showIncompleteHint ? (
        <p className="mt-2 px-1 text-xs text-faint">
          Enter a valid {country.name} number ({meta.maxDigits} digits).
        </p>
      ) : null}
    </div>
  );
}
