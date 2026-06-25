"use client";

import { useState } from "react";
import { Mail } from "lucide-react";
import { Country, DEFAULT_COUNTRY, toE164 } from "@/lib/countries";
import { CountryCodeSelect } from "./CountryCodeSelect";
import { Input } from "./Input";

export type LoginIdentityFieldsProps = {
  /** Emits the combined destination for requestOtp: an E.164 phone ("+91…") or the raw email. */
  onChange: (destination: string) => void;
  /** Label for the phone field (e.g. "Phone number" / "Admin phone number"). */
  phoneLabel?: string;
  autoFocus?: boolean;
};

// Phone-first login identity entry: a country-code selector + local-number field that combine into an
// E.164 destination, with a toggle to "Use email instead" (preserves email login). Self-contained — it
// emits the final `destination` string via onChange; the parent keeps treating that as before.
export function LoginIdentityFields({
  onChange,
  phoneLabel = "Phone number",
  autoFocus
}: LoginIdentityFieldsProps) {
  const [mode, setMode] = useState<"phone" | "email">("phone");
  const [country, setCountry] = useState<Country>(DEFAULT_COUNTRY);
  const [localNumber, setLocalNumber] = useState("");
  const [email, setEmail] = useState("");

  function handleCountry(next: Country) {
    setCountry(next);
    onChange(toE164(next.dialCode, localNumber));
  }

  function handleLocal(value: string) {
    setLocalNumber(value);
    onChange(toE164(country.dialCode, value));
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
    onChange(toE164(country.dialCode, localNumber));
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
            placeholder="99999 99999"
            value={localNumber}
            onChange={(event) => handleLocal(event.target.value)}
            autoFocus={autoFocus}
            aria-label={`${phoneLabel} (national number)`}
            className="h-11 min-w-0 flex-1 rounded-xl border border-border bg-elevated px-4 text-fg placeholder:text-faint outline-none transition-colors focus:border-brand focus:ring-2 focus:ring-brand-ring"
          />
        </div>
      </div>
      <button
        type="button"
        onClick={switchToEmail}
        className="text-xs font-medium text-muted transition-colors hover:text-fg"
      >
        Use email instead
      </button>
    </div>
  );
}
