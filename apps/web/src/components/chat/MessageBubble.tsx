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
  Trash2,
  X
} from "lucide-react";
import type { Message } from "@/lib/api";
import { getMediaDownloadUrl } from "@/lib/api";
import { Avatar } from "@/components";
import { cn } from "@/lib/cn";
import { formatTime, metadataString } from "./format";

export type MessageBubbleProps = {
  message: Message;
  isOwn: boolean;
  /** The message this one replies to (resolved from the loaded list), or null if unknown/none. */
  quoted?: Message | null;
  currentUserId?: string;
  onEdit: (messageId: string, body: string) => Promise<void>;
  onDelete: (messageId: string) => Promise<void>;
  onReply?: (message: Message) => void;
  onForward?: (message: Message) => void;
};

export function MessageBubble({
  message,
  isOwn,
  quoted,
  currentUserId,
  onEdit,
  onDelete,
  onReply,
  onForward
}: MessageBubbleProps) {
  const isMedia = Boolean(message.media_id);
  const isDeleted = message.status === "deleted";
  const isEdited = Boolean(message.edited_at);
  const canEdit = isOwn && !isDeleted && !isMedia;
  const canDelete = isOwn && !isDeleted;
  const canReply = !isDeleted && Boolean(onReply);
  const canForward = !isDeleted && Boolean(onForward);
  const isForwarded = Boolean(message.metadata?.forwarded_from);

  const [isEditing, setIsEditing] = useState(false);
  const [editDraft, setEditDraft] = useState(message.body ?? "");
  const [isBusy, setIsBusy] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  const menuRef = useRef<HTMLDivElement | null>(null);

  // Reply/forward are available on any non-deleted message; edit (own text) / delete (own) too.
  const hasActions = !isEditing && (canReply || canForward || canEdit || canDelete);

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
      className={cn(
        "group flex items-end gap-2 animate-slide-up",
        isOwn ? "flex-row-reverse" : "flex-row"
      )}
    >
      {!isOwn && <Avatar id={message.sender_user_id} size="sm" className="mb-1" />}

      <div className={cn("flex max-w-[78%] flex-col gap-1", isOwn ? "items-end" : "items-start")}>
        <div
          className={cn(
            "rounded-2xl px-3.5 py-2.5 text-sm leading-relaxed shadow-subtle",
            isOwn
              ? "rounded-br-md bg-brand text-white"
              : "rounded-bl-md border border-border bg-elevated text-fg"
          )}
        >
          {!isDeleted && !isEditing && isForwarded ? (
            <p
              className={cn(
                "mb-1 flex items-center gap-1 text-[11px] italic",
                isOwn ? "text-white/60" : "text-faint"
              )}
            >
              <Forward className="h-3 w-3" aria-hidden /> Forwarded
            </p>
          ) : null}

          {!isDeleted && !isEditing && message.reply_to_message_id ? (
            <div
              className={cn(
                "mb-1.5 rounded-md border-l-2 px-2 py-1 text-xs",
                isOwn ? "border-white/50 bg-white/10" : "border-brand bg-bg"
              )}
            >
              <p className={cn("font-medium", isOwn ? "text-white/90" : "text-brand-hover")}>
                {quoted
                  ? quoted.sender_user_id === currentUserId
                    ? "You"
                    : `#${quoted.sender_user_id.slice(0, 8)}`
                  : "Original message"}
              </p>
              <p className={cn("truncate", isOwn ? "text-white/70" : "text-muted")}>
                {quoted ? messageSnippet(quoted) : "…"}
              </p>
            </div>
          ) : null}

          {isDeleted ? (
            <p className={cn("italic", isOwn ? "text-white/70" : "text-faint")}>Message deleted</p>
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
                  className="inline-flex items-center gap-1 rounded-md bg-white/15 px-2 py-1 text-xs font-medium disabled:opacity-50"
                  disabled={isBusy || !editDraft.trim()}
                  onClick={saveEdit}
                  type="button"
                >
                  <Check className="h-3.5 w-3.5" aria-hidden /> Save
                </button>
                <button
                  className="inline-flex items-center gap-1 rounded-md bg-white/10 px-2 py-1 text-xs font-medium disabled:opacity-50"
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

        <div className={cn("flex items-center gap-2 px-1", isOwn ? "flex-row-reverse" : "flex-row")}>
          <span className="text-[11px] text-faint">
            {time}
            {isEdited && !isDeleted ? " · edited" : ""}
          </span>

          {isOwn && !isDeleted ? <ReadTicks message={message} /> : null}

          {hasActions && (
            <div className="relative" ref={menuRef}>
              <button
                type="button"
                onClick={() => setMenuOpen((open) => !open)}
                aria-label="Message actions"
                aria-haspopup="menu"
                aria-expanded={menuOpen}
                className="rounded p-0.5 text-faint transition-colors hover:text-fg"
              >
                <MoreHorizontal className="h-4 w-4" aria-hidden />
              </button>

              {menuOpen && (
                <div
                  role="menu"
                  className="absolute right-0 top-full z-30 mt-1 w-36 overflow-hidden rounded-lg border border-border bg-surface shadow-elevated animate-scale-in"
                >
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
          className="group block w-full overflow-hidden rounded-lg"
          aria-label="Open image"
        >
          {/* Presigned URLs are dynamic/remote; next/image would need remotePatterns config, so a
              plain <img> is intentional. */}
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            alt={caption || "Image attachment"}
            className="max-h-64 w-full cursor-pointer rounded-lg object-cover transition-transform duration-200 group-hover:scale-[1.03]"
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
          className="max-h-72 w-full rounded-lg bg-black"
        />
      ) : null}

      {/* AUDIO — plays inline with native controls */}
      {isAudio && url && !loadFailed ? (
        <audio controls src={url} onError={handleMediaError} className="w-full" />
      ) : null}

      {/* PDF / other / failed-preview — the whole file row is the click target */}
      {(!inlinePreviewable || loadFailed) && canResolve ? (
        <button
          type="button"
          onClick={openInNewTab}
          disabled={isOpening}
          className={cn(
            "flex w-full items-center gap-3 rounded-lg px-3 py-2.5 text-left transition-colors disabled:opacity-50",
            isOwn ? "bg-white/15 hover:bg-white/25" : "bg-bg hover:bg-border"
          )}
        >
          <FileText className="h-5 w-5 shrink-0" aria-hidden />
          <span className="min-w-0 flex-1 truncate text-sm font-medium">{filename}</span>
          <Download className="h-4 w-4 shrink-0 opacity-70" aria-hidden />
        </button>
      ) : null}

      {caption ? (
        <p className={cn("text-sm", isOwn ? "text-white/90" : "text-muted")}>{caption}</p>
      ) : null}

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
