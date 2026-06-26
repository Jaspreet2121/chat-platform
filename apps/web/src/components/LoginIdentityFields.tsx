"use client";

import { useMemo, useState } from "react";
import { Mail } from "lucide-react";
import {
  AsYouType,
  type CountryCode,
  getExampleNumber,
  parsePhoneNumber
} from "libphonenumber-js";
import examples from "libphonenumber-js/examples.mobile.json";
import { Country, DEFAULT_COUNTRY } from "@/lib/countries";
import { CountryCodeSelect } from "./CountryCodeSelect";
import { Input } from "./Input";

export type LoginIdentityFieldsProps = {
  /** Emits the combined destination for requestOtp: an E.164 phone ("+91…") or the raw email. */
  onChange: (destination: string) => void;
  /** Label for the phone field (e.g. "Phone number" / "Admin phone number"). */
  phoneLabel?: string;
  /** Hide the "Use email instead" toggle (phone-only contexts, e.g. find-a-user-by-phone). */
  phoneOnly?: boolean;
  autoFocus?: boolean;
};

// Per-country phone metadata from libphonenumber-js: an example placeholder (formatted national) and the
// max national digit count for that country (used to cap input). The example's national length is the
// canonical mobile length (India 10, UAE 9, …) — a strict, intuitive cap; the button still gates on full
// per-country validity below.
function phoneMeta(iso: CountryCode): { maxDigits: number; placeholder: string } {
  const example = getExampleNumber(iso, examples);
  if (!example) return { maxDigits: 15, placeholder: "phone number" };
  return {
    maxDigits: example.nationalNumber.length,
    placeholder: new AsYouType(iso).input(example.nationalNumber)
  };
}

// Format the typed digits per country (AsYouType) after capping to the country's max length.
function formatLocal(iso: CountryCode, raw: string, maxDigits: number): string {
  const digits = raw.replace(/\D/g, "").slice(0, maxDigits);
  return new AsYouType(iso).input(digits);
}

// Valid national number → E.164 ("+91…"); otherwise "" (so the submit button stays disabled). This is
// the SAME E.164 requestOtp already accepts — backend/lib unchanged.
function toE164(iso: CountryCode, formatted: string): string {
  const digits = formatted.replace(/\D/g, "");
  if (!digits) return "";
  try {
    const parsed = parsePhoneNumber(digits, iso);
    return parsed && parsed.isValid() ? parsed.number : "";
  } catch {
    return "";
  }
}

// Phone-first login identity entry: a country-code selector + per-country-validated national number that
// combine into an E.164 destination, with a toggle to "Use email instead" (preserves email login).
// Self-contained — it emits the final `destination` via onChange; the parent treats that as before.
export function LoginIdentityFields({
  onChange,
  phoneLabel = "Phone number",
  phoneOnly = false,
  autoFocus
}: LoginIdentityFieldsProps) {
  const [mode, setMode] = useState<"phone" | "email">("phone");
  const [country, setCountry] = useState<Country>(DEFAULT_COUNTRY);
  const [localNumber, setLocalNumber] = useState("");
  const [email, setEmail] = useState("");

  const meta = useMemo(() => phoneMeta(country.iso2 as CountryCode), [country]);

  // The number is complete/valid for the country exactly when toE164 yields a value.
  const e164 = toE164(country.iso2 as CountryCode, localNumber);
  const hasDigits = localNumber.replace(/\D/g, "").length > 0;
  const showIncompleteHint = mode === "phone" && hasDigits && e164 === "";

  function handleCountry(next: Country) {
    setCountry(next);
    const iso = next.iso2 as CountryCode;
    const { maxDigits } = phoneMeta(iso);
    // Re-format + re-validate the existing digits against the newly selected country.
    const reformatted = formatLocal(iso, localNumber, maxDigits);
    setLocalNumber(reformatted);
    onChange(toE164(iso, reformatted));
  }

  function handleLocal(raw: string) {
    const iso = country.iso2 as CountryCode;
    const formatted = formatLocal(iso, raw, meta.maxDigits);
    setLocalNumber(formatted);
    onChange(toE164(iso, formatted));
  }

  function handleEmail(value: string) {
    setEmail(value);
    onChange(value.trim());
  }

  function switchToEmail() {
    setMode("email");
    onChange(email.trim());
  }

  function switchToPhone() {
    setMode("phone");
    onChange(toE164(country.iso2 as CountryCode, localNumber));
  }

  if (mode === "email") {
    return (
      <div className="space-y-2">
        <Input
          label="Email"
          type="email"
          leftIcon={<Mail className="h-4 w-4" aria-hidden />}
          inputMode="email"
          autoComplete="email"
          placeholder="you@example.com"
          value={email}
          onChange={(event) => handleEmail(event.target.value)}
          autoFocus={autoFocus}
        />
        <button
          type="button"
          onClick={switchToPhone}
          className="text-xs font-medium text-muted transition-colors hover:text-fg"
        >
          Use phone instead
        </button>
      </div>
    );
  }

  return (
    <div className="space-y-2">
      <div>
        <label className="mb-1.5 block text-sm font-medium text-muted">{phoneLabel}</label>
        <div className="flex gap-2">
          <CountryCodeSelect value={country} onChange={handleCountry} />
          <input
            inputMode="tel"
            autoComplete="tel-national"
            placeholder={meta.placeholder}
            value={localNumber}
            onChange={(event) => handleLocal(event.target.value)}
            autoFocus={autoFocus}
            aria-label={`${phoneLabel} (national number)`}
            className="h-11 min-w-0 flex-1 rounded-xl border border-border bg-elevated px-4 text-fg placeholder:text-faint outline-none transition-colors focus:border-brand focus:ring-2 focus:ring-brand-ring"
          />
        </div>
        {showIncompleteHint ? (
          <p className="mt-1 text-xs text-faint">
            Enter a valid {country.name} number ({meta.maxDigits} digits).
          </p>
        ) : null}
      </div>
      {!phoneOnly ? (
        <button
          type="button"
          onClick={switchToEmail}
          className="text-xs font-medium text-muted transition-colors hover:text-fg"
        >
          Use email instead
        </button>
      ) : null}
    </div>
  );
}
