import type { Message } from "@/lib/api";

/** Short clock label (e.g. "14:05") for a message timestamp; empty string if unparseable. */
export function formatTime(iso?: string | null): string {
  if (!iso) return "";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

/** Human file size for upload previews. */
export function formatFileSize(size: number): string {
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`;
  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
}

/** Safely read a string-valued key from a message's free-form metadata. */
export function metadataString(metadata: Message["metadata"], key: string): string | null {
  if (!metadata || typeof metadata[key] !== "string") return null;
  return metadata[key] as string;
}

/**
 * A clean sender label: the profile's display_name if set, otherwise a friendly generic ("Member") —
 * never a raw user-id hash. Real names appear once users set a profile. Shared by message group headers
 * and reply-quotes so the fallback is consistent.
 */
export function senderDisplayName(displayName?: string | null): string {
  const name = displayName?.trim();
  return name && name.length > 0 ? name : "Member";
}
