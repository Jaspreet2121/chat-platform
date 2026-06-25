import { useEffect, useRef, useState } from "react";
import {
  Check,
  CheckCheck,
  CornerUpLeft,
  Download,
  FileText,
  Forward,
  MoreHorizontal,
  Pencil,
  Star,
  Trash2,
  X
} from "lucide-react";
import type { Message } from "@/lib/api";
import { getMediaDownloadUrl } from "@/lib/api";
import { Avatar } from "@/components";
import { cn } from "@/lib/cn";
import { formatTime, metadataString, senderDisplayName } from "./format";
import { VoiceMessagePlayer } from "./VoiceMessagePlayer";
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
  onUnstar
}: MessageBubbleProps) {
  // Resolve the sender's profile (cached, deduped) to show their real avatar on others' messages.
  const senderProfile = useUserProfile(isOwn ? null : message.sender_user_id);
  const isMedia = Boolean(message.media_id);
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
  const menuRef = useRef<HTMLDivElement | null>(null);

  // React/reply/forward/star are available on any non-deleted message; edit (own text) / delete (own) too.
  const hasActions =
    !isEditing && (canReact || canReply || canForward || canStar || canEdit || canDelete);

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

      <div className={cn("flex max-w-[78%] flex-col gap-1", isOwn ? "items-end" : "items-start")}>
        <div
          className={cn(
            "text-sm leading-relaxed",
            seamlessMedia
              ? // Seamless photo/video: no bubble surface — only the media's own rounded box shows.
                "max-w-full text-fg"
              : cn(
                  // Single clean surface (no nested ring/glow). Theme-aware tokens: own = green, others =
                  // blue on light; tinted glass on dark. Hover darkens bg + border smoothly.
                  "rounded-2xl border px-3.5 py-2.5 shadow-pop transition-colors dark:backdrop-blur-md",
                  isOwn
                    ? "rounded-br-md bg-[var(--bubble-own-bg)] text-[var(--bubble-own-fg)] border-[var(--bubble-own-border)] hover:bg-[var(--bubble-own-bg-hover)] hover:border-[var(--bubble-own-border-hover)]"
                    : "rounded-bl-md bg-[var(--bubble-other-bg)] text-[var(--bubble-other-fg)] border-[var(--bubble-other-border)] hover:bg-[var(--bubble-other-bg-hover)] hover:border-[var(--bubble-other-border-hover)]"
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
          ) : isMedia ? (
            <MediaMessageContent message={message} isOwn={isOwn} />
          ) : (
            <p
              className={cn(
                "whitespace-pre-wrap break-words",
                hasActions && "cursor-pointer"
              )}
              onClick={hasActions ? () => setMenuOpen((open) => !open) : undefined}
            >
              {message.body || message.message_type}
            </p>
          )}
        </div>

        {reactions.length > 0 && (
          <div className={cn("flex flex-wrap gap-1", isOwn ? "justify-end" : "justify-start")}>
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
                    "inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-xs backdrop-blur-sm transition-all disabled:cursor-default enabled:hover:scale-105",
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

        <div className={cn("flex items-center gap-2 px-1", isOwn ? "flex-row-reverse" : "flex-row")}>
          <span className="text-[11px] text-faint">
            {time}
            {isEdited && !isDeleted ? " · edited" : ""}
          </span>

          {isStarred ? (
            <span title="Starred" aria-label="Starred">
              <Star className="h-3 w-3 text-amber-400" fill="currentColor" aria-hidden />
            </span>
          ) : null}

          {isOwn && !isDeleted ? <ReadTicks message={message} /> : null}

          {hasActions && (
            <div className="relative" ref={menuRef}>
              <button
                type="button"
                onClick={() => setMenuOpen((open) => !open)}
                aria-label="Message actions"
                aria-haspopup="menu"
                aria-expanded={menuOpen}
                className="rounded-md p-1 text-faint transition-colors hover:bg-elevated hover:text-fg"
              >
                <MoreHorizontal className="h-4 w-4" aria-hidden />
              </button>

              {menuOpen && (
                <div
                  role="menu"
                  className={cn(
                    "absolute top-full z-30 mt-1 w-48 overflow-hidden rounded-xl border border-border/70 bg-surface/90 shadow-elevated backdrop-blur-xl animate-scale-in",
                    // Open toward the screen interior so the menu never clips the edge: own messages sit
                    // on the right (anchor right, extend left); others sit on the left (anchor left,
                    // extend right).
                    isOwn ? "right-0" : "left-0"
                  )}
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
      </div>
    </div>
  );
}

// A one-line preview of a message for the reply quote block (text body, or a media-type label).
function messageSnippet(m: Message): string {
  if (m.status === "deleted") return "Message deleted";
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
function ReadTicks({ message }: { message: Message }) {
  const read = (message.read_by_count ?? 0) > 0;
  const delivered = (message.delivered_by_count ?? 0) > 0;

  if (read) {
    return (
      <span title="Read" aria-label="Read">
        <CheckCheck className="h-3.5 w-3.5 text-sky-400" aria-hidden />
      </span>
    );
  }
  if (delivered) {
    return (
      <span title="Delivered" aria-label="Delivered">
        <CheckCheck className="h-3.5 w-3.5 text-faint" aria-hidden />
      </span>
    );
  }
  return (
    <span title="Sent" aria-label="Sent">
      <Check className="h-3.5 w-3.5 text-faint" aria-hidden />
    </span>
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
