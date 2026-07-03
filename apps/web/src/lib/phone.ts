import {
  AsYouType,
  type CountryCode,
  getExampleNumber,
  parsePhoneNumber
} from "libphonenumber-js";
import examples from "libphonenumber-js/examples.mobile.json";

// Shared phone formatting/validation helpers (libphonenumber-js) used by both the login identity
// fields and the sidebar contact search. Keeping one copy means both surfaces format/validate phone
// numbers identically — and produce the SAME E.164 the backend stores (so by-phone lookup matches).

// Per-country metadata: an example placeholder (formatted national) + the max national digit count.
// The example's national length is the canonical mobile length (India 10, UAE 9, …) — a strict cap.
export function phoneMeta(iso: CountryCode): { maxDigits: number; placeholder: string } {
  const example = getExampleNumber(iso, examples);
  if (!example) return { maxDigits: 15, placeholder: "phone number" };
  return {
    maxDigits: example.nationalNumber.length,
    placeholder: new AsYouType(iso).input(example.nationalNumber)
  };
}

// Format typed digits per country (AsYouType) after capping to the country's max length.
export function formatLocal(iso: CountryCode, raw: string, maxDigits: number): string {
  const digits = raw.replace(/\D/g, "").slice(0, maxDigits);
  return new AsYouType(iso).input(digits);
}

// Region-less normalization for the CHAT search (no country dropdown): accepts a bare national number
// (normalized with the default region, e.g. "98765 43210" → "+91…") OR a full international "+<cc>…"
// number. Returns E.164 when valid, "" otherwise — the same shape the backend stores, so lookups match.
export function toE164Loose(raw: string, defaultIso: CountryCode): string {
  const cleaned = raw.replace(/[^\d+]/g, "");
  if (cleaned.replace(/\D/g, "") === "") return "";
  try {
    const parsed = parsePhoneNumber(cleaned, defaultIso);
    return parsed && parsed.isValid() ? parsed.number : "";
  } catch {
    return "";
  }
}

// Format a chat-search input as-you-type: keeps an optional leading "+", formats via the default
// region (or internationally when "+"-prefixed). Digits capped at 15 (E.164 max).
export function formatSearchInput(raw: string, defaultIso: CountryCode): string {
  const plus = raw.trimStart().startsWith("+") ? "+" : "";
  const digits = raw.replace(/\D/g, "").slice(0, 15);
  if (!digits) return plus;
  return new AsYouType(defaultIso).input(plus + digits);
}

// Valid national number → E.164 ("+91…"); otherwise "" (callers gate their submit on a non-empty value).
export function toE164(iso: CountryCode, formatted: string): string {
  const digits = formatted.replace(/\D/g, "");
  if (!digits) return "";
  try {
    const parsed = parsePhoneNumber(digits, iso);
    return parsed && parsed.isValid() ? parsed.number : "";
  } catch {
    return "";
  }
}
