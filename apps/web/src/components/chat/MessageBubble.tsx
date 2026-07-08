"use client";

import dynamic from "next/dynamic";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import {
  Check,
  CheckCheck,
  Copy,
  CornerUpLeft,
  Download,
  FileText,
  Forward,
  MapPin,
  MoreHorizontal,
  Pencil,
  Phone,
  Star,
  Trash2,
  Users,
  Video,
  X
} from "lucide-react";
import type { Message } from "@/lib/api";
import { getMediaDownloadUrl } from "@/lib/api";
import { Avatar } from "@/components";
import { cn } from "@/lib/cn";
import { formatTime, metadataString, senderDisplayName } from "./format";
import { VoiceMessagePlayer } from "./VoiceMessagePlayer";
import { LinkifiedText } from "./LinkifiedText";

// Leaflet needs `window` — load the interactive map client-side only (no SSR) so the build/SSR never
// touch it. A neutral skeleton reserves the space while the chunk loads.
const LeafletMap = dynamic(() => import("./LeafletMap"), {
  ssr: false,
  loading: () => <div className="bg-elevated" style={{ height: 150 }} aria-hidden />
});
import { useUserProfile } from "./useUserProfile";

// WhatsApp-style quick reactions, shown as a bar at the top of the ⋯ menu.
const QUICK_EMOJIS = ["👍", "❤️", "😂", "😮", "😢", "🙏"];

export type MessageBubbleProps = {
  message: Message;
  isOwn: boolean;
  /** Briefly flash this message (e.g. after jumping to it from a search/starred result). */
  isHighlighted?: boolean;
  /** In a grouped run, the avatar is shown once in the group header — hide the per-bubble avatar. */
  hideAvatar?: boolean;
  /** The message this one replies to (resolved from the loaded list), or null if unknown/none. */
  quoted?: Message | null;
  currentUserId?: string;
  onEdit: (messageId: string, body: string) => Promise<void>;
  onDelete: (messageId: string) => Promise<void>;
  onReply?: (message: Message) => void;
  onForward?: (message: Message) => void;
  /** Set/change the caller's reaction (one per user). Available on own AND others' messages. */
  onReact?: (messageId: string, emoji: string) => void;
  /** Remove the caller's reaction. */
  onRemoveReaction?: (messageId: string) => void;
  /** Star (bookmark) this message for the caller — private. */
  onStar?: (messageId: string) => void;
  /** Unstar this message. */
  onUnstar?: (messageId: string) => void;
  /** Stop an active live-location share (own live_location bubble only). */
  onStopLiveLocation?: (messageId: string) => void;
};

export function MessageBubble({
  message,
  isOwn,
  isHighlighted,
  hideAvatar,
  quoted,
  currentUserId,
  onEdit,
  onDelete,
  onReply,
  onForward,
  onReact,
  onRemoveReaction,
  onStar,
  onUnstar,
  onStopLiveLocation
}: MessageBubbleProps) {
  // Resolve the sender's profile (cached, deduped) to show their real avatar on others' messages.
  const senderProfile = useUserProfile(isOwn ? null : message.sender_user_id);
  const isMedia = Boolean(message.media_id);
  const isLocation = message.message_type === "location" && !isMedia;
  const isLiveLocation = message.message_type === "live_location" && !isMedia;
  const isDeleted = message.status === "deleted";
  // Photo/video render seamlessly (no surrounding bubble) — only the media's own rounded surface shows.
  // Voice + files keep the bubble. A deleted media message falls back to the text "deleted" bubble.
  const mediaContentType = metadataString(message.metadata, "content_type") ?? "";
  const isImageOrVideo = isMedia && /^(image|video)\//.test(mediaContentType);
  const seamlessMedia = isImageOrVideo && !isDeleted;
  const isEdited = Boolean(message.edited_at);
  const canEdit = isOwn && !isDeleted && !isMedia;
  const canDelete = isOwn && !isDeleted;
  const canReply = !isDeleted && Boolean(onReply);
  const canForward = !isDeleted && Boolean(onForward);
  const canReact = !isDeleted && Boolean(onReact);
  const canStar = !isDeleted && Boolean(onStar) && Boolean(onUnstar);
  // Copy the message text — any non-deleted message that HAS body text (skips pure media/voice with none).
  const canCopy = !isDeleted && Boolean((message.body ?? "").trim());
  const isStarred = Boolean(message.is_starred);
  const isForwarded = Boolean(message.metadata?.forwarded_from);

  const reactions = message.reactions ?? [];
  const myReaction = message.my_reaction ?? null;

  // One reaction per user: tapping your current emoji removes it; tapping another sets/changes it.
  function toggleReaction(emoji: string) {
    if (myReaction === emoji) {
      onRemoveReaction?.(message.message_id);
    } else {
      onReact?.(message.message_id, emoji);
    }
  }

  function toggleStar() {
    if (isStarred) {
      onUnstar?.(message.message_id);
    } else {
      onStar?.(message.message_id);
    }
  }

  const [isEditing, setIsEditing] = useState(false);
  const [editDraft, setEditDraft] = useState(message.body ?? "");
  const [isBusy, setIsBusy] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  const [copied, setCopied] = useState(false);
  const menuRef = useRef<HTMLDivElement | null>(null);

  // React/reply/forward/star/copy are available on any non-deleted message; edit (own text) / delete (own) too.
  const hasActions =
    !isEditing && (canReact || canReply || canForward || canStar || canCopy || canEdit || canDelete);

  async function copyBody() {
    try {
      await navigator.clipboard.writeText(message.body ?? "");
      // Keep the menu open briefly to flash "Copied", then close.
      setCopied(true);
      setTimeout(() => {
        setCopied(false);
        setMenuOpen(false);
      }, 1200);
    } catch {
      setMenuOpen(false);
    }
  }

  // Close the actions popover on click-outside / Esc. Listeners attach only while open, AFTER the
  // opening click has fired, so opening the menu never immediately closes it.
  useEffect(() => {
    if (!menuOpen) return;
    function onDown(event: MouseEvent) {
      if (menuRef.current && !menuRef.current.contains(event.target as Node)) setMenuOpen(false);
    }
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape") setMenuOpen(false);
    }
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [menuOpen]);

  // Position the actions/reaction menu so it always stays fully within the viewport — no matter the
  // bubble size (a wide map bubble pushes the ⋯ trigger far to one side, which a static right/left
  // anchor would clip off-screen). We measure the trigger on open and clamp the menu's left edge to
  // [8px, viewport − menuWidth − 8px], then express it relative to the trigger (its containing block).
  const MENU_WIDTH = 208; // w-48 (192px) + a little breathing room
  const [menuLeft, setMenuLeft] = useState(0);
  useLayoutEffect(() => {
    if (!menuOpen || !menuRef.current) return;
    const rect = menuRef.current.getBoundingClientRect();
    const vw = window.innerWidth;
    const margin = 8;
    // Preferred anchor: own (right-aligned) → menu's right edge at the trigger; others → left edge.
    const preferredAbsLeft = isOwn ? rect.right - MENU_WIDTH : rect.left;
    const clampedAbsLeft = Math.min(
      Math.max(preferredAbsLeft, margin),
      Math.max(margin, vw - MENU_WIDTH - margin)
    );
    setMenuLeft(clampedAbsLeft - rect.left);
  }, [menuOpen, isOwn]);

  function startEdit() {
    setEditDraft(message.body ?? "");
    setIsEditing(true);
  }

  async function saveEdit() {
    const next = editDraft.trim();
    if (!next) return;
    setIsBusy(true);
    try {
      await onEdit(message.message_id, next);
      setIsEditing(false);
    } catch {
      // Failure status is surfaced by the parent; keep the edit box open.
    } finally {
      setIsBusy(false);
    }
  }

  async function removeMessage() {
    setIsBusy(true);
    try {
      await onDelete(message.message_id);
    } catch {
      // Failure status is surfaced by the parent.
    } finally {
      setIsBusy(false);
    }
  }

  const time = formatTime(message.created_at);

  // WhatsApp-style IN-BUBBLE stamp: time (+ edited) and, on own messages, the read-ticks — floated to
  // the bubble's bottom-right so text wraps around it. Seamless media gets an overlay pill instead.
  const stamp = !isDeleted && !isEditing ? (
    <span
      className={cn(
        "pointer-events-none float-right ml-2 mt-1.5 flex translate-y-0.5 items-center gap-1 text-[10px] leading-none",
        seamlessMedia
          ? "absolute bottom-2 right-2 float-none mt-0 rounded-full bg-black/45 px-1.5 py-1 text-white backdrop-blur-sm"
          : isOwn
            ? "text-white/75"
            : "text-faint"
      )}
    >
      {isStarred ? (
        <Star className="h-2.5 w-2.5 text-amber-400" fill="currentColor" aria-hidden />
      ) : null}
      {time}
      {isEdited ? <span className="italic">· edited</span> : null}
      {isOwn ? <ReadTicks message={message} inline /> : null}
    </span>
  ) : null;

  // Missed-call entry (Slice-5b): a minimal, non-interactive system pill — NO bubble chrome, reactions,
  // edit, or read-ticks. Aligned by sender (own = right) like a normal message, red accent, phone/video
  // icon + label from metadata. (All hooks above have already run, so this early return is hook-safe.)
  if (message.message_type === "call") {
    const isVideoCall = metadataString(message.metadata, "call_type") === "video";
    const isGroupCall = metadataString(message.metadata, "call_kind") === "group";
    const CallIcon = isGroupCall ? Users : isVideoCall ? Video : Phone;
    const callLabel = isGroupCall
      ? "Missed group call"
      : `Missed ${isVideoCall ? "video" : "voice"} call`;
    return (
      <div className={cn("flex px-1 py-0.5", isOwn ? "justify-end" : "justify-start")}>
        <span className="inline-flex items-center gap-2 rounded-full bg-red-500/10 px-3 py-1.5 text-xs font-medium text-red-500">
          <CallIcon className="h-3.5 w-3.5 shrink-0" aria-hidden />
          <span>{callLabel}</span>
          <span className="tabular-nums text-red-500/60">{formatTime(message.created_at)}</span>
        </span>
      </div>
    );
  }

  return (
    <div
      id={`msg-${message.message_id}`}
      className={cn(
        "group flex items-end gap-2 animate-bubble-in rounded-2xl transition-colors duration-700",
        isOwn ? "flex-row-reverse" : "flex-row",
        // Brief flash when jumped-to from a search/starred result (fades via the transition above).
        isHighlighted && "bg-brand/15"
      )}
    >
      {!isOwn && !hideAvatar && (
        <Avatar
          id={message.sender_user_id}
          name={senderProfile?.display_name ?? undefined}
          imageUrl={senderProfile?.avatar_url}
          size="sm"
          className="mb-1"
        />
      )}

      <div className={cn("flex min-w-0 max-w-[78%] flex-col", isOwn ? "items-end" : "items-start")}>
        <div
          className={cn(
            "text-sm leading-snug",
            seamlessMedia
              ? // Seamless photo/video: no bubble surface — only the media's own rounded box shows.
                // (relative so the overlay time/ticks pill can sit on the media's corner.)
                "relative max-w-full text-fg"
              : cn(
                  // Locked periwinkle bubbles: OUTGOING = accent gradient with white text and a soft
                  // glow; INCOMING = periwinkle-tinted surface with dark text. 18px radius, 5px tail
                  // corner on the sender's side.
                  "rounded-[18px] px-3 py-1.5 transition-shadow",
                  isOwn
                    ? "bubble-own-gradient rounded-br-[5px] text-white shadow-accent-glow"
                    : "rounded-bl-[5px] bg-[var(--bubble-other-bg)] text-[var(--bubble-other-fg)] shadow-subtle hover:bg-[var(--bubble-other-bg-hover)]"
                )
          )}
        >
          {!isDeleted && !isEditing && isForwarded ? (
            <p className="mb-1 flex items-center gap-1 text-[11px] italic opacity-70">
              <Forward className="h-3 w-3" aria-hidden /> Forwarded
            </p>
          ) : null}

          {!isDeleted && !isEditing && message.reply_to_message_id ? (
            <div className="mb-1.5 rounded-md border-l-2 border-black/20 bg-black/[0.05] px-2 py-1 text-xs dark:border-white/25 dark:bg-white/[0.06]">
              <p className="font-medium opacity-90">
                {quoted
                  ? quoted.sender_user_id === currentUserId
                    ? "You"
                    : senderDisplayName(null)
                  : "Original message"}
              </p>
              <p className="truncate opacity-70">{quoted ? messageSnippet(quoted) : "…"}</p>
            </div>
          ) : null}

          {isDeleted ? (
            <p className="italic opacity-70">Message deleted</p>
          ) : isEditing ? (
            <div className="space-y-2">
              <input
                className="w-64 max-w-full rounded-lg border border-border bg-bg px-3 py-2 text-sm text-fg outline-none focus:border-brand focus:ring-2 focus:ring-brand-ring"
                disabled={isBusy}
                onChange={(event) => setEditDraft(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Enter") {
                    event.preventDefault();
                    void saveEdit();
                  }
                  if (event.key === "Escape") setIsEditing(false);
                }}
                value={editDraft}
                autoFocus
              />
              <div className="flex gap-1.5">
                <button
                  className="inline-flex items-center gap-1 rounded-md bg-black/10 px-2 py-1 text-xs font-medium disabled:opacity-50 dark:bg-white/15"
                  disabled={isBusy || !editDraft.trim()}
                  onClick={saveEdit}
                  type="button"
                >
                  <Check className="h-3.5 w-3.5" aria-hidden /> Save
                </button>
                <button
                  className="inline-flex items-center gap-1 rounded-md bg-black/[0.06] px-2 py-1 text-xs font-medium disabled:opacity-50 dark:bg-white/10"
                  disabled={isBusy}
                  onClick={() => setIsEditing(false)}
                  type="button"
                >
                  <X className="h-3.5 w-3.5" aria-hidden /> Cancel
                </button>
              </div>
            </div>
          ) : isLiveLocation ? (
            <>
              <LiveLocationMessageContent
                message={message}
                isOwn={isOwn}
                onStop={onStopLiveLocation}
              />
              {stamp}
            </>
          ) : isLocation ? (
            <>
              <LocationMessageContent message={message} />
              {stamp}
            </>
          ) : isMedia ? (
            <>
              <MediaMessageContent message={message} isOwn={isOwn} />
              {stamp}
            </>
          ) : (
            <p
              className={cn(
                "whitespace-pre-wrap break-words",
                hasActions && "cursor-pointer"
              )}
              onClick={hasActions ? () => setMenuOpen((open) => !open) : undefined}
            >
              {message.body ? <LinkifiedText text={message.body} /> : message.message_type}
              {stamp}
            </p>
          )}
        </div>

        {reactions.length > 0 && (
          <div
            className={cn(
              "z-[1] -mt-1.5 flex flex-wrap gap-1 px-1.5",
              isOwn ? "justify-end" : "justify-start"
            )}
          >
            {reactions.map((reaction) => {
              const mine = myReaction === reaction.emoji;
              return (
                <button
                  key={reaction.emoji}
                  type="button"
                  onClick={() => toggleReaction(reaction.emoji)}
                  disabled={!canReact}
                  aria-pressed={mine}
                  aria-label={`${reaction.emoji} ${reaction.count}${mine ? ", your reaction — tap to remove" : ""}`}
                  className={cn(
                    "inline-flex items-center gap-0.5 rounded-full border px-1.5 py-0 text-[11px] backdrop-blur-sm transition-all disabled:cursor-default enabled:hover:scale-105",
                    mine
                      ? "border-brand/60 bg-brand/15 text-fg shadow-glow-sm"
                      : "border-border/70 bg-surface/70 text-muted enabled:hover:bg-elevated"
                  )}
                >
                  <span className="text-sm leading-none">{reaction.emoji}</span>
                  <span className="tabular-nums">{reaction.count}</span>
                </button>
              );
            })}
          </div>
        )}

      </div>

      {/* Actions trigger — a ROW sibling of the bubble (WhatsApp-chevron style): no vertical space.
          Desktop: appears on hover. Mobile: faint but always tappable (bubble text-tap also opens it). */}
      {hasActions && (
        <div className="relative shrink-0 self-center" ref={menuRef}>
              <button
                type="button"
                onClick={() => setMenuOpen((open) => !open)}
                aria-label="Message actions"
                aria-haspopup="menu"
                aria-expanded={menuOpen}
                className="rounded-md p-1 text-faint transition-all hover:bg-elevated hover:text-fg max-md:opacity-50 md:opacity-0 md:group-hover:opacity-100 md:focus-visible:opacity-100"
              >
                <MoreHorizontal className="h-4 w-4" aria-hidden />
              </button>

              {menuOpen && (
                <div
                  role="menu"
                  style={{ left: menuLeft }}
                  className="absolute top-full z-30 mt-1 w-48 overflow-hidden rounded-xl border border-border/70 bg-surface/90 shadow-elevated backdrop-blur-xl animate-scale-in"
                >
                  {canReact && (
                    <div className="flex items-center justify-between gap-0.5 border-b border-border px-1.5 py-1.5">
                      {QUICK_EMOJIS.map((emoji) => (
                        <button
                          key={emoji}
                          role="menuitem"
                          type="button"
                          onClick={() => {
                            setMenuOpen(false);
                            toggleReaction(emoji);
                          }}
                          aria-label={
                            myReaction === emoji
                              ? `Remove ${emoji} reaction`
                              : `React ${emoji}`
                          }
                          className={cn(
                            "rounded-md px-1.5 py-1 text-base leading-none transition-transform hover:scale-125",
                            myReaction === emoji && "bg-brand/15"
                          )}
                        >
                          {emoji}
                        </button>
                      ))}
                    </div>
                  )}
                  {canReply && (
                    <button
                      role="menuitem"
                      type="button"
                      onClick={() => {
                        setMenuOpen(false);
                        onReply?.(message);
                      }}
                      className="flex w-full items-center gap-2 px-3 py-2 text-left text-sm text-fg transition-colors hover:bg-elevated"
                    >
                      <CornerUpLeft className="h-4 w-4" aria-hidden /> Reply
                    </button>
                  )}
                  {canForward && (
                    <button
                      role="menuitem"
                      type="button"
                      onClick={() => {
                        setMenuOpen(false);
                        onForward?.(message);
                      }}
                      className="flex w-full items-center gap-2 px-3 py-2 text-left text-sm text-fg transition-colors hover:bg-elevated"
                    >
                      <Forward className="h-4 w-4" aria-hidden /> Forward
                    </button>
                  )}
                  {canCopy && (
                    <button
                      role="menuitem"
                      type="button"
                      onClick={() => void copyBody()}
                      className="flex w-full items-center gap-2 px-3 py-2 text-left text-sm text-fg transition-colors hover:bg-elevated"
                    >
                      {copied ? (
                        <Check className="h-4 w-4 text-success" aria-hidden />
                      ) : (
                        <Copy className="h-4 w-4" aria-hidden />
                      )}{" "}
                      {copied ? "Copied" : "Copy"}
                    </button>
                  )}
                  {canStar && (
                    <button
                      role="menuitem"
                      type="button"
                      onClick={() => {
                        setMenuOpen(false);
                        toggleStar();
                      }}
                      className="flex w-full items-center gap-2 px-3 py-2 text-left text-sm text-fg transition-colors hover:bg-elevated"
                    >
                      <Star
                        className={cn("h-4 w-4", isStarred && "text-amber-400")}
                        fill={isStarred ? "currentColor" : "none"}
                        aria-hidden
                      />{" "}
                      {isStarred ? "Unstar" : "Star"}
                    </button>
                  )}
                  {canEdit && (
                    <button
                      role="menuitem"
                      type="button"
                      disabled={isBusy}
                      onClick={() => {
                        setMenuOpen(false);
                        startEdit();
                      }}
                      className="flex w-full items-center gap-2 px-3 py-2 text-left text-sm text-fg transition-colors hover:bg-elevated disabled:opacity-50"
                    >
                      <Pencil className="h-4 w-4" aria-hidden /> Edit
                    </button>
                  )}
                  {canDelete && (
                    <button
                      role="menuitem"
                      type="button"
                      disabled={isBusy}
                      onClick={() => {
                        setMenuOpen(false);
                        void removeMessage();
                      }}
                      className="flex w-full items-center gap-2 px-3 py-2 text-left text-sm text-danger transition-colors hover:bg-danger/10 disabled:opacity-50"
                    >
                      <Trash2 className="h-4 w-4" aria-hidden /> Delete
                    </button>
                  )}
                </div>
              )}
        </div>
      )}
    </div>
  );
}

// A one-line preview of a message for the reply quote block (text body, or a media-type label).
function messageSnippet(m: Message): string {
  if (m.status === "deleted") return "Message deleted";
  if (m.message_type === "live_location" && !m.media_id) return "📍 Live location";
  if (m.message_type === "location" && !m.media_id) return "📍 Location";
  if (m.media_id) {
    const contentType = (m.metadata?.content_type as string) || "";
    if (contentType.startsWith("image/")) return "📷 Photo";
    if (contentType.startsWith("video/")) return "🎬 Video";
    if (contentType.startsWith("audio/")) return "🎤 Audio";
    return "📎 Attachment";
  }
  return m.body || "Message";
}

// Read-receipt ticks for own messages: single check = sent, double = delivered, blue double = read.
// Counts come from the timeline projection (durable across reloads) + live receipt_updated events.
// 1:1 exact; in groups "read" means at least one other participant has read it.
function ReadTicks({ message, inline }: { message: Message; inline?: boolean }) {
  const read = (message.read_by_count ?? 0) > 0;
  const delivered = (message.delivered_by_count ?? 0) > 0;

  if (read) {
    return (
      <span title="Read" aria-label="Read">
        <CheckCheck
          className={cn("h-3.5 w-3.5", inline ? "text-white" : "text-brand-hover")}
          aria-hidden
        />
      </span>
    );
  }
  if (delivered) {
    return (
      <span title="Delivered" aria-label="Delivered">
        <CheckCheck
          className={cn("h-3.5 w-3.5", inline ? "text-white/60" : "text-faint")}
          aria-hidden
        />
      </span>
    );
  }
  return (
    <span title="Sent" aria-label="Sent">
      <Check className={cn("h-3.5 w-3.5", inline ? "text-white/60" : "text-faint")} aria-hidden />
    </span>
  );
}

// A shared CURRENT-location message: an interactive Leaflet/OpenStreetMap map (no API key) centered on
// the point with a pin, plus an "Open in Maps" action. Tapping "Open in Maps" opens the device's maps
// app via a geo/https URL (Apple Maps on iOS, Google Maps on Android/desktop).
function LocationMessageContent({ message }: { message: Message }) {
  const lat = Number(metadataString(message.metadata, "lat"));
  const lng = Number(metadataString(message.metadata, "lng"));

  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    return <p className="flex items-center gap-1.5">📍 Location</p>;
  }

  const mapsUrl = `https://www.google.com/maps?q=${lat},${lng}`;
  const coords = `${lat.toFixed(5)}, ${lng.toFixed(5)}`;

  return (
    <div className="my-0.5 w-[min(240px,62vw)] max-w-full overflow-hidden rounded-xl border border-black/10 dark:border-white/15">
      <LeafletMap lat={lat} lng={lng} height={150} />
      <a
        href={mapsUrl}
        target="_blank"
        rel="noopener noreferrer"
        className="flex items-center gap-2 bg-surface px-2.5 py-2 no-underline"
      >
        <MapPin className="h-4 w-4 shrink-0 text-brand-hover" aria-hidden />
        <div className="min-w-0 flex-1">
          <p className="truncate text-xs font-medium text-fg">Shared location</p>
          <p className="truncate text-[11px] tabular-nums text-muted">{coords}</p>
        </div>
        <span className="shrink-0 text-[11px] font-medium text-brand-hover">Open in Maps</span>
      </a>
    </div>
  );
}

// A LIVE-location message: the same interactive Leaflet map, but the marker pulses and follows the
// sharer's latest position (patched into the message metadata live, so this bubble re-renders as new
// coords arrive). Shows "live until HH:MM" while active (+ an honest note that updates only flow while
// the app is open), a "Stop sharing" control on the sharer's own bubble, and "Live location ended" after.
function LiveLocationMessageContent({
  message,
  isOwn,
  onStop
}: {
  message: Message;
  isOwn: boolean;
  onStop?: (messageId: string) => void;
}) {
  // A ticking clock so the bubble flips to "ended" once the window passes, even if no final broadcast
  // arrived (e.g. the sharer's app was backgrounded at expiry). Reads the clock off render (impure).
  const [now, setNow] = useState(0);
  useEffect(() => {
    const tick = () => setNow(Date.now());
    const first = setTimeout(tick, 0);
    const id = setInterval(tick, 30000);
    return () => {
      clearTimeout(first);
      clearInterval(id);
    };
  }, []);

  const lat = Number(metadataString(message.metadata, "lat"));
  const lng = Number(metadataString(message.metadata, "lng"));
  const expiresAt = Date.parse(metadataString(message.metadata, "expires_at") ?? "");
  const liveFlag = metadataString(message.metadata, "live") !== "false";
  const notExpired = !Number.isFinite(expiresAt) || now === 0 || now < expiresAt;
  const isLive = liveFlag && notExpired;

  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    return <p className="flex items-center gap-1.5">📍 Live location</p>;
  }

  const mapsUrl = `https://www.google.com/maps?q=${lat},${lng}`;
  const untilLabel = Number.isFinite(expiresAt)
    ? new Date(expiresAt).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })
    : null;

  return (
    <div className="my-0.5 w-[min(240px,62vw)] max-w-full overflow-hidden rounded-xl border border-black/10 dark:border-white/15">
      <LeafletMap lat={lat} lng={lng} live={isLive} height={150} />
      <div className="space-y-1.5 bg-surface px-2.5 py-2">
        <a
          href={mapsUrl}
          target="_blank"
          rel="noopener noreferrer"
          className="flex items-center gap-2 no-underline"
        >
          <span className="relative flex h-2.5 w-2.5 shrink-0" aria-hidden>
            {isLive ? (
              <>
                <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-success opacity-75" />
                <span className="relative inline-flex h-2.5 w-2.5 rounded-full bg-success" />
              </>
            ) : (
              <span className="relative inline-flex h-2.5 w-2.5 rounded-full bg-faint" />
            )}
          </span>
          <div className="min-w-0 flex-1">
            <p className="truncate text-xs font-medium text-fg">
              {isLive ? "Live location" : "Live location ended"}
            </p>
            <p className="truncate text-[11px] text-muted">
              {isLive
                ? untilLabel
                  ? `Shared until ${untilLabel}`
                  : "Sharing now"
                : `${lat.toFixed(5)}, ${lng.toFixed(5)}`}
            </p>
          </div>
          <span className="shrink-0 text-[11px] font-medium text-brand-hover">Open in Maps</span>
        </a>

        {isLive ? (
          <p className="text-[10px] leading-tight text-faint">
            Live location updates while the app is open.
          </p>
        ) : null}

        {isLive && isOwn && onStop ? (
          <button
            type="button"
            onClick={() => onStop(message.message_id)}
            className="w-full rounded-lg bg-danger/10 px-2 py-1 text-[11px] font-medium text-danger transition-colors hover:bg-danger/15"
          >
            Stop sharing
          </button>
        ) : null}
      </div>
    </div>
  );
}

function MediaMessageContent({ message, isOwn }: { message: Message; isOwn: boolean }) {
  const objectKey = metadataString(message.metadata, "object_key");
  const contentType = metadataString(message.metadata, "content_type");
  const mediaId = message.media_id;
  const isImage = Boolean(contentType && contentType.startsWith("image/"));
  const isVideo = Boolean(contentType && contentType.startsWith("video/"));
  const isAudio = Boolean(contentType && contentType.startsWith("audio/"));
  const inlinePreviewable = isImage || isVideo || isAudio;
  const canResolve = Boolean(mediaId && objectKey);

  const [url, setUrl] = useState<string | null>(null);
  const [loadFailed, setLoadFailed] = useState(false);
  const [isOpening, setIsOpening] = useState(false);
  const [openError, setOpenError] = useState("");
  const [lightboxOpen, setLightboxOpen] = useState(false);
  const retriedRef = useRef(false);

  const caption = message.body || message.caption;
  const filename = metadataString(message.metadata, "filename") || "Attachment";

  // Resolve the signed GET URL once for inline-previewable media (image/video/audio) so it can be the
  // <img>/<video>/<audio> src. PDFs and other types resolve on click instead (openInNewTab).
  useEffect(() => {
    if (!inlinePreviewable || !mediaId || !objectKey) return;
    let isActive = true;
    getMediaDownloadUrl(mediaId, objectKey)
      .then((response) => {
        if (isActive) setUrl(response.download_url);
      })
      .catch(() => {
        if (isActive) setLoadFailed(true);
      });
    return () => {
      isActive = false;
    };
  }, [inlinePreviewable, mediaId, objectKey]);

  // Signed URLs expire (~900s). When an inline preview fails to load, re-resolve ONCE before falling
  // back to the clickable file row, so a stale URL self-heals without a manual retry.
  async function handleMediaError() {
    if (retriedRef.current || !mediaId || !objectKey) {
      setLoadFailed(true);
      return;
    }
    retriedRef.current = true;
    try {
      const response = await getMediaDownloadUrl(mediaId, objectKey);
      setUrl(response.download_url);
    } catch {
      setLoadFailed(true);
    }
  }

  // Resolve-on-click for non-inline files (pdf/other, or a failed preview) — open in a new tab.
  async function openInNewTab() {
    if (url) {
      window.open(url, "_blank", "noopener,noreferrer");
      return;
    }
    if (!mediaId || !objectKey) return;
    setIsOpening(true);
    setOpenError("");
    try {
      const response = await getMediaDownloadUrl(mediaId, objectKey);
      setUrl(response.download_url);
      window.open(response.download_url, "_blank", "noopener,noreferrer");
    } catch (error) {
      setOpenError(error instanceof Error ? error.message : "Could not open media.");
    } finally {
      setIsOpening(false);
    }
  }

  return (
    <div className="space-y-2">
      {/* IMAGE — the thumbnail itself opens a full-size lightbox */}
      {isImage && url && !loadFailed ? (
        <button
          type="button"
          onClick={() => setLightboxOpen(true)}
          className="group block w-full overflow-hidden rounded-2xl"
          aria-label="Open image"
        >
          {/* Presigned URLs are dynamic/remote; next/image would need remotePatterns config, so a
              plain <img> is intentional. */}
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            alt={caption || "Image attachment"}
            className="max-h-64 w-full cursor-pointer rounded-2xl object-cover transition-transform duration-200 group-hover:scale-[1.03]"
            loading="lazy"
            onError={handleMediaError}
            src={url}
          />
        </button>
      ) : null}

      {/* VIDEO — plays inline with native controls */}
      {isVideo && url && !loadFailed ? (
        <video
          controls
          src={url}
          onError={handleMediaError}
          className="max-h-72 w-full rounded-2xl bg-black"
        />
      ) : null}

      {/* VOICE / AUDIO — custom futuristic player (waveform + animated playback) instead of the native
          <audio controls>. Mounts as soon as the media is resolvable so it can show its own loading
          state while the signed URL resolves; falls back to the file row only after a load failure. */}
      {isAudio && canResolve && !loadFailed ? (
        <VoiceMessagePlayer
          url={url}
          isOwn={isOwn}
          seed={message.message_id}
          onError={handleMediaError}
        />
      ) : null}

      {/* PDF / other / failed-preview — the whole file row is the click target */}
      {(!inlinePreviewable || loadFailed) && canResolve ? (
        <button
          type="button"
          onClick={openInNewTab}
          disabled={isOpening}
          className="flex w-full items-center gap-3 rounded-lg bg-black/10 px-3 py-2.5 text-left transition-colors hover:bg-black/15 disabled:opacity-50 dark:bg-white/10 dark:hover:bg-white/20"
        >
          <FileText className="h-5 w-5 shrink-0" aria-hidden />
          <span className="min-w-0 flex-1 truncate text-sm font-medium">{filename}</span>
          <Download className="h-4 w-4 shrink-0 opacity-70" aria-hidden />
        </button>
      ) : null}

      {caption ? <p className="text-sm text-muted">{caption}</p> : null}

      {openError ? <p className="text-xs text-danger">{openError}</p> : null}

      {lightboxOpen && url ? (
        <Lightbox
          src={url}
          alt={caption || "Image attachment"}
          onClose={() => setLightboxOpen(false)}
        />
      ) : null}
    </div>
  );
}

function Lightbox({
  src,
  alt,
  onClose
}: {
  src: string;
  alt: string;
  onClose: () => void;
}) {
  useEffect(() => {
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape") onClose();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 p-4 animate-fade-in"
      onClick={onClose}
      role="dialog"
      aria-modal="true"
    >
      <button
        type="button"
        onClick={onClose}
        aria-label="Close"
        className="absolute right-4 top-4 rounded-lg p-2 text-white/80 transition-colors hover:bg-white/10 hover:text-white"
      >
        <X className="h-6 w-6" aria-hidden />
      </button>
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img
        src={src}
        alt={alt}
        onClick={(event) => event.stopPropagation()}
        className="max-h-[90vh] max-w-[90vw] rounded-lg object-contain animate-scale-in"
      />
    </div>
  );
}
