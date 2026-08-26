// Pure logic behind the Automated-replies settings UI (102): defaults, local validation, and the
// PATCH payload build. Kept out of the component so the wire shape is unit-testable — the server
// REPLACES a provided block wholesale, so sending a subtly wrong object silently wipes settings.

import {
  AUTO_REPLY_BODY_MAX,
  AUTO_REPLY_EXCEPT_MAX,
  type AutoReplyAway,
  type AutoReplyGreeting,
  type AutoReplySchedule
} from "@/lib/api";

/** The browser's IANA zone, used when a user first switches away-mode to "custom". */
export function localTimezone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
  } catch {
    return "UTC";
  }
}

/** A sensible first custom schedule: Mon–Fri, 18:00 → 09:00 (crosses midnight, which is legal). */
export function defaultSchedule(): AutoReplySchedule {
  return {
    timezone: localTimezone(),
    ranges: [{ days: [1, 2, 3, 4, 5], start: "18:00", end: "09:00" }]
  };
}

export type ValidationError =
  | "body_required"
  | "body_too_long"
  | "schedule_required"
  | "invalid_time"
  | "no_days"
  | "too_many_exceptions"
  | "invalid_resend";

const HHMM = /^([01]\d|2[0-3]):([0-5]\d)$/;

/** Mirrors the server's away validation so the user sees the problem before the round-trip. */
export function validateAway(away: AutoReplyAway): ValidationError | null {
  // A DISABLED block may have an empty body — only an enabled one must say something.
  if (away.enabled && !away.body?.trim()) return "body_required";
  if ((away.body?.length ?? 0) > AUTO_REPLY_BODY_MAX) return "body_too_long";
  if ((away.except_ids?.length ?? 0) > AUTO_REPLY_EXCEPT_MAX) return "too_many_exceptions";

  if (away.mode === "custom") {
    const ranges = away.schedule?.ranges ?? [];
    if (!away.schedule?.timezone || ranges.length === 0) return "schedule_required";
    for (const range of ranges) {
      if (range.days.length === 0) return "no_days";
      if (!HHMM.test(range.start) || !HHMM.test(range.end)) return "invalid_time";
    }
  }

  return null;
}

export function validateGreeting(greeting: AutoReplyGreeting): ValidationError | null {
  if (greeting.enabled && !greeting.body?.trim()) return "body_required";
  if ((greeting.body?.length ?? 0) > AUTO_REPLY_BODY_MAX) return "body_too_long";
  if ((greeting.except_ids?.length ?? 0) > AUTO_REPLY_EXCEPT_MAX) return "too_many_exceptions";
  if (
    !Number.isInteger(greeting.resend_after_days) ||
    greeting.resend_after_days < 1 ||
    greeting.resend_after_days > 365
  ) {
    return "invalid_resend";
  }
  return null;
}

export const VALIDATION_COPY: Record<ValidationError, string> = {
  body_required: "Write a message to turn this on.",
  body_too_long: `Keep it under ${AUTO_REPLY_BODY_MAX} characters.`,
  schedule_required: "Add at least one time range.",
  invalid_time: "Times must look like 18:00.",
  no_days: "Pick at least one day.",
  too_many_exceptions: `You can exclude at most ${AUTO_REPLY_EXCEPT_MAX} people.`,
  invalid_resend: "Repeat must be between 1 and 365 days."
};

/**
 * Build the `away` block exactly as the server wants it:
 *   * "always" carries schedule: null (the server drops any schedule anyway — sending one is noise);
 *   * except_ids only ride the "except" audience, so switching audience away from it cannot leave a
 *     stale exclusion list applied;
 *   * a blank body is sent as null, not "".
 */
export function buildAway(away: AutoReplyAway): AutoReplyAway {
  const body = away.body?.trim() ? away.body.trim() : null;

  return {
    enabled: away.enabled,
    mode: away.mode,
    schedule: away.mode === "custom" ? (away.schedule ?? defaultSchedule()) : null,
    audience: away.audience,
    except_ids: away.audience === "except" ? (away.except_ids ?? []) : [],
    body
  };
}

export function buildGreeting(greeting: AutoReplyGreeting): AutoReplyGreeting {
  const body = greeting.body?.trim() ? greeting.body.trim() : null;

  return {
    enabled: greeting.enabled,
    audience: greeting.audience,
    except_ids: greeting.audience === "except" ? (greeting.except_ids ?? []) : [],
    body,
    resend_after_days: greeting.resend_after_days
  };
}

/** Normalise a GET response into fully-populated local state (the server may omit except_ids). */
export function withDefaults(away: AutoReplyAway): AutoReplyAway {
  return { ...away, except_ids: away.except_ids ?? [] };
}

export function greetingWithDefaults(greeting: AutoReplyGreeting): AutoReplyGreeting {
  return {
    ...greeting,
    except_ids: greeting.except_ids ?? [],
    resend_after_days: greeting.resend_after_days ?? 14
  };
}

export const WEEKDAYS: Array<{ value: number; label: string }> = [
  { value: 1, label: "Mon" },
  { value: 2, label: "Tue" },
  { value: 3, label: "Wed" },
  { value: 4, label: "Thu" },
  { value: 5, label: "Fri" },
  { value: 6, label: "Sat" },
  { value: 7, label: "Sun" }
];

export const AUDIENCE_OPTIONS: Array<{ value: AutoReplyAway["audience"]; label: string }> = [
  { value: "everyone", label: "Everyone" },
  { value: "contacts", label: "My contacts" },
  { value: "non_contacts", label: "People who aren't contacts" },
  { value: "except", label: "Everyone except…" }
];
