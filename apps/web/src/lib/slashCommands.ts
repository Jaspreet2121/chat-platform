// Pure logic behind the composer's "/" picker (100): which commands are offered, how a typed
// fragment filters them, and how a command's template resolves against the caller's own profile.
// Kept out of the component so the gating rules are unit-testable — offering a command whose
// required profile field is unset would send a message containing a literal "{upi_id}".

import type { QuickReply, SlashCommand, UserProfile } from "@/lib/api";

/** A row in the picker: either a built-in command or one of the user's own quick replies. */
export type PickerItem =
  | { source: "command"; name: string; description: string; command: SlashCommand }
  | { source: "quick_reply"; name: string; description: string; reply: QuickReply };

/** The profile fields a command's `requires` / `{placeholder}` can name. */
const PROFILE_FIELDS = [
  "upi_id",
  "address",
  "website",
  "business_email",
  "business_hours"
] as const;

type ProfileField = (typeof PROFILE_FIELDS)[number];

function profileValue(profile: UserProfile | null, field: string): string | null {
  if (!profile) return null;
  if (!(PROFILE_FIELDS as readonly string[]).includes(field)) return null;
  const raw = profile[field as ProfileField];
  return typeof raw === "string" && raw.trim() ? raw.trim() : null;
}

/**
 * A command is offered only when its `requires` field is set on the caller's profile. This is the
 * whole point of the gate: /pay's template is "Pay me on UPI: {upi_id}", so offering it without a
 * UPI id would send that literal text.
 */
export function commandAvailable(command: SlashCommand, profile: UserProfile | null): boolean {
  if (!command.requires) return true;
  return profileValue(profile, command.requires) !== null;
}

/**
 * Resolve a "text" command's template from the profile. Returns null when any placeholder is
 * unresolved, so an un-fillable template can never reach the composer.
 */
export function resolveTemplate(
  template: string,
  profile: UserProfile | null
): string | null {
  let unresolved = false;

  const filled = template.replace(/\{([a-z_]+)\}/g, (_match, field: string) => {
    const value = profileValue(profile, field);
    if (value === null) {
      unresolved = true;
      return "";
    }
    return value;
  });

  return unresolved ? null : filled;
}

/**
 * The draft is in "slash mode" while it is a single token starting with "/" — i.e. the very first
 * character is "/" and no whitespace has been typed yet. Returns the fragment after the slash, or
 * null when the picker should not be open.
 */
export function slashFragment(draft: string): string | null {
  if (!draft.startsWith("/")) return null;
  const fragment = draft.slice(1);
  if (/\s/.test(fragment)) return null;
  return fragment;
}

/**
 * "action" commands the WEB client can actually perform. The server's list is shared across clients,
 * so an action this build has no path for (today: /contact — there is no contact-card message type on
 * web) is hidden rather than offered as a row that would do nothing.
 */
export const SUPPORTED_ACTIONS = new Set(["qr", "location"]);

export function commandSupported(command: SlashCommand): boolean {
  return command.kind !== "action" || SUPPORTED_ACTIONS.has(command.name);
}

/** Build the picker list: gated built-ins first (server order), then the user's own quick replies. */
export function pickerItems(
  commands: SlashCommand[],
  quickReplies: QuickReply[],
  profile: UserProfile | null
): PickerItem[] {
  const commandItems: PickerItem[] = commands
    .filter((command) => commandSupported(command) && commandAvailable(command, profile))
    .map((command) => ({
      source: "command",
      name: command.name,
      description:
        command.label ??
        (command.template ? resolveTemplate(command.template, profile) ?? command.template : ""),
      command
    }));

  const replyItems: PickerItem[] = quickReplies.map((reply) => ({
    source: "quick_reply",
    name: reply.shortcut,
    description: reply.body,
    reply
  }));

  return [...commandItems, ...replyItems];
}

/** Prefix-filter by the typed fragment (case-insensitive). An empty fragment shows everything. */
export function filterItems(items: PickerItem[], fragment: string): PickerItem[] {
  const needle = fragment.trim().toLowerCase();
  if (!needle) return items;
  return items.filter((item) => item.name.toLowerCase().startsWith(needle));
}

/** The caption the /qr action attaches to the UPI QR image. Locked to the doc's wording. */
export function qrCaption(profile: UserProfile | null): string {
  return `Pay me on UPI: ${profile?.upi_id?.trim() ?? ""}`;
}
