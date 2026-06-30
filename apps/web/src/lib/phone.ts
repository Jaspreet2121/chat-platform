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
