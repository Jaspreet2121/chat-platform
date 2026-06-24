import { useEffect, useState } from "react";
import { Check, Pencil, Trash2, X } from "lucide-react";
import type { Message } from "@/lib/api";
import { getMediaDownloadUrl } from "@/lib/api";
import { Avatar } from "@/components";
import { cn } from "@/lib/cn";
import { formatTime, metadataString } from "./format";

export type MessageBubbleProps = {
  message: Message;
  isOwn: boolean;
  onEdit: (messageId: string, body: string) => Promise<void>;
  onDelete: (messageId: string) => Promise<void>;
};

export function MessageBubble({ message, isOwn, onEdit, onDelete }: MessageBubbleProps) {
  const isMedia = Boolean(message.media_id);
  const isDeleted = message.status === "deleted";
  const isEdited = Boolean(message.edited_at);
  const canEdit = isOwn && !isDeleted && !isMedia;
  const canDelete = isOwn && !isDeleted;

  const [isEditing, setIsEditing] = useState(false);
  const [editDraft, setEditDraft] = useState(message.body ?? "");
  const [isBusy, setIsBusy] = useState(false);

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
            <p className="whitespace-pre-wrap break-words">{message.body || message.message_type}</p>
          )}
        </div>

        <div className={cn("flex items-center gap-2 px-1", isOwn ? "flex-row-reverse" : "flex-row")}>
          <span className="text-[11px] text-faint">
            {time}
            {isEdited && !isDeleted ? " · edited" : ""}
          </span>

          {!isEditing && (canEdit || canDelete) && (
            <div className="flex gap-1 opacity-0 transition-opacity group-hover:opacity-100">
              {canEdit && (
                <button
                  className="text-faint transition-colors hover:text-fg disabled:opacity-50"
                  disabled={isBusy}
                  onClick={startEdit}
                  type="button"
                  aria-label="Edit message"
                  title="Edit"
                >
                  <Pencil className="h-3.5 w-3.5" aria-hidden />
                </button>
              )}
              {canDelete && (
                <button
                  className="text-faint transition-colors hover:text-danger disabled:opacity-50"
                  disabled={isBusy}
                  onClick={removeMessage}
                  type="button"
                  aria-label="Delete message"
                  title="Delete"
                >
                  <Trash2 className="h-3.5 w-3.5" aria-hidden />
                </button>
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

function MediaMessageContent({ message, isOwn }: { message: Message; isOwn: boolean }) {
  const objectKey = metadataString(message.metadata, "object_key");
  const contentType = metadataString(message.metadata, "content_type");
  const mediaId = message.media_id;
  const isImage = Boolean(contentType && contentType.startsWith("image/"));
  const canResolve = Boolean(mediaId && objectKey);

  const [previewUrl, setPreviewUrl] = useState<string | null>(null);
  const [previewFailed, setPreviewFailed] = useState(false);

  // Resolve the download URL once when an image preview is possible, reusing the same resolver the
  // "Open media" link uses. The resolved URL is shared with the link below so opening an image does
  // not trigger a second request.
  useEffect(() => {
    if (!isImage || !mediaId || !objectKey) return;
    let isActive = true;
    getMediaDownloadUrl(mediaId, objectKey)
      .then((response) => {
        if (isActive) setPreviewUrl(response.download_url);
      })
      .catch(() => {
        if (isActive) setPreviewFailed(true);
      });
    return () => {
      isActive = false;
    };
  }, [isImage, mediaId, objectKey]);

  const showPreview = isImage && previewUrl && !previewFailed;
  const subtle = isOwn ? "text-white/70" : "text-faint";

  return (
    <div className="space-y-2">
      <p className="text-sm font-medium">Media attachment</p>
      {message.body || message.caption ? (
        <p className={cn("text-sm", isOwn ? "text-white/90" : "text-muted")}>
          {message.body || message.caption}
        </p>
      ) : null}
      {showPreview ? (
        // Presigned media URLs are dynamic/remote; next/image would need remotePatterns config,
        // so a plain <img> is intentional here.
        // eslint-disable-next-line @next/next/no-img-element
        <img
          alt={message.caption || message.body || "Image attachment"}
          className="max-h-64 w-full rounded-lg object-cover"
          loading="lazy"
          onError={() => setPreviewFailed(true)}
          src={previewUrl as string}
        />
      ) : null}
      <p className={cn("break-all text-[11px]", subtle)}>{message.media_id}</p>
      {canResolve ? (
        <OpenMediaLink
          mediaId={mediaId as string}
          objectKey={objectKey as string}
          prefetchedUrl={isImage ? previewUrl : null}
          isOwn={isOwn}
        />
      ) : null}
    </div>
  );
}

function OpenMediaLink({
  mediaId,
  objectKey,
  prefetchedUrl,
  isOwn
}: {
  mediaId: string;
  objectKey: string;
  prefetchedUrl?: string | null;
  isOwn: boolean;
}) {
  const [downloadUrl, setDownloadUrl] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState("");

  async function handleOpenMedia() {
    if (prefetchedUrl) {
      setDownloadUrl(prefetchedUrl);
      window.open(prefetchedUrl, "_blank", "noopener,noreferrer");
      return;
    }
    setIsLoading(true);
    setError("");
    try {
      const response = await getMediaDownloadUrl(mediaId, objectKey);
      setDownloadUrl(response.download_url);
      window.open(response.download_url, "_blank", "noopener,noreferrer");
    } catch (openError) {
      setError(openError instanceof Error ? openError.message : "Could not open media.");
    } finally {
      setIsLoading(false);
    }
  }

  return (
    <div className="flex flex-wrap items-center gap-2">
      <button
        className={cn(
          "rounded-md px-2.5 py-1 text-xs font-medium disabled:opacity-50",
          isOwn ? "bg-white/15 hover:bg-white/25" : "bg-bg hover:bg-border"
        )}
        disabled={isLoading}
        onClick={handleOpenMedia}
        type="button"
      >
        {isLoading ? "Opening..." : "Open media"}
      </button>
      {downloadUrl ? (
        <a
          className={cn("text-xs font-medium underline", isOwn ? "text-white/90" : "text-brand")}
          href={downloadUrl}
          rel="noreferrer"
          target="_blank"
        >
          Link ready
        </a>
      ) : null}
      {error ? <span className="text-xs text-danger">{error}</span> : null}
    </div>
  );
}
