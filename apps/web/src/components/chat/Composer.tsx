import { FormEvent, RefObject, useEffect, useRef, useState } from "react";
import { Camera, CornerUpLeft, FileText, Image as ImageIcon, Mic, Plus, Send, Smile, Square, X } from "lucide-react";
import { Button, IconButton } from "@/components";
import { cn } from "@/lib/cn";
import { formatFileSize } from "./format";
import { useVoiceRecorder } from "./useVoiceRecorder";

export type ComposerProps = {
  draft: string;
  onDraftChange: (value: string) => void;
  onSubmit: (event: FormEvent<HTMLFormElement>) => void;
  hasConversation: boolean;
  isSending: boolean;
  selectedFile: File | null;
  onPickFile: () => void;
  onFileChange: (file: File | null) => void;
  onClearFile: () => void;
  mediaStatus: string;
  fileInputRef: RefObject<HTMLInputElement>;
  acceptTypes: string;
  /** When replying, a quoted preview shown above the input. */
  replyPreview?: { name: string; snippet: string } | null;
  onCancelReply?: () => void;
  /** Upload + send a recorded voice message. Should reject on failure (preview is kept for retry). */
  onSendVoice: (file: File) => Promise<void>;
};

export function Composer({
  draft,
  onDraftChange,
  onSubmit,
  hasConversation,
  isSending,
  selectedFile,
  onPickFile,
  onFileChange,
  onClearFile,
  mediaStatus,
  fileInputRef,
  acceptTypes,
  replyPreview,
  onCancelReply,
  onSendVoice
}: ComposerProps) {
  const canSend = hasConversation && (Boolean(draft.trim()) || Boolean(selectedFile)) && !isSending;

  const recorder = useVoiceRecorder();
  const [isSendingVoice, setIsSendingVoice] = useState(false);
  // Quick emoji tray (inserts into the draft — a lightweight picker, not a decoration).
  const [emojiOpen, setEmojiOpen] = useState(false);
  const emojiRef = useRef<HTMLDivElement>(null);
  // "+" attachment menu — ONLY the capabilities the upload flow really supports (no dead buttons):
  // gallery media, camera capture (mobile; desktop falls back to the picker), PDF documents.
  const [attachOpen, setAttachOpen] = useState(false);
  const attachRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!attachOpen) return;
    function onDown(event: MouseEvent | TouchEvent) {
      if (attachRef.current && !attachRef.current.contains(event.target as Node)) {
        setAttachOpen(false);
      }
    }
    document.addEventListener("mousedown", onDown);
    document.addEventListener("touchstart", onDown);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("touchstart", onDown);
    };
  }, [attachOpen]);

  // Re-point the ONE hidden input (accept + camera capture) for the chosen source, then open it —
  // the existing upload flow (validation, compression, presign) is untouched.
  function pickWith(accept: string, capture?: string) {
    const input = fileInputRef.current;
    if (input) {
      input.setAttribute("accept", accept);
      if (capture) input.setAttribute("capture", capture);
      else input.removeAttribute("capture");
    }
    setAttachOpen(false);
    onPickFile();
  }

  useEffect(() => {
    if (!emojiOpen) return;
    function onDown(event: MouseEvent | TouchEvent) {
      if (emojiRef.current && !emojiRef.current.contains(event.target as Node)) setEmojiOpen(false);
    }
    document.addEventListener("mousedown", onDown);
    document.addEventListener("touchstart", onDown);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("touchstart", onDown);
    };
  }, [emojiOpen]);
  // Show the mic only when the row is otherwise empty (WhatsApp-style); recording/preview then takes
  // over the whole row (replacing text + attach + send) via the recorder.status branch below.
  const canRecord = hasConversation && !isSending && !selectedFile && !draft.trim();

  async function sendVoice() {
    if (!recorder.file) return;
    setIsSendingVoice(true);
    try {
      await onSendVoice(recorder.file);
      recorder.reset();
    } catch {
      // Keep the preview so the user can retry; the parent surfaces the error via mediaStatus.
    } finally {
      setIsSendingVoice(false);
    }
  }

  return (
    <form
      className="border-t border-border bg-surface p-2.5 pb-[max(0.625rem,env(safe-area-inset-bottom))] sm:p-3"
      onSubmit={onSubmit}
    >
      {replyPreview ? (
        <div className="mb-2 flex items-center gap-2 rounded-lg border-l-2 border-brand bg-elevated px-3 py-2">
          <CornerUpLeft className="h-4 w-4 shrink-0 text-brand-hover" aria-hidden />
          <div className="min-w-0 flex-1">
            <p className="text-xs font-medium text-brand-hover">Replying to {replyPreview.name}</p>
            <p className="truncate text-xs text-muted">{replyPreview.snippet}</p>
          </div>
          <button
            type="button"
            onClick={onCancelReply}
            aria-label="Cancel reply"
            className="shrink-0 rounded-md p-1 text-faint transition-colors hover:text-fg"
          >
            <X className="h-4 w-4" aria-hidden />
          </button>
        </div>
      ) : null}

      {selectedFile ? (
        <div className="mb-3 flex items-center justify-between gap-3 rounded-lg border border-border bg-elevated px-3 py-2 text-sm">
          <span className="min-w-0 truncate text-muted">
            {selectedFile.name} · {formatFileSize(selectedFile.size)}
          </span>
          <button
            className="shrink-0 rounded-md p-1 text-faint transition-colors hover:text-fg disabled:opacity-50"
            disabled={isSending}
            onClick={onClearFile}
            type="button"
            aria-label="Remove attachment"
          >
            <X className="h-4 w-4" aria-hidden />
          </button>
        </div>
      ) : null}

      {mediaStatus ? <p className="mb-2 px-1 text-xs text-brand-hover">{mediaStatus}</p> : null}
      {recorder.error ? <p className="mb-2 px-1 text-xs text-danger">{recorder.error}</p> : null}

      {/* Hidden file input stays mounted so the attach button can trigger it. */}
      <input
        className="hidden"
        disabled={!hasConversation || isSending}
        onChange={(event) => onFileChange(event.target.files?.[0] ?? null)}
        ref={fileInputRef}
        type="file"
        accept={acceptTypes}
      />

      {recorder.status === "recording" ? (
        <div className="flex items-center gap-2 rounded-xl border border-border bg-elevated px-3 py-1.5">
          <span className="relative flex h-2.5 w-2.5 shrink-0" aria-hidden>
            <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-red-500 opacity-75" />
            <span className="relative inline-flex h-2.5 w-2.5 rounded-full bg-red-500" />
          </span>
          <span className="text-sm tabular-nums text-fg">{formatDuration(recorder.elapsedMs)}</span>
          <span className="flex-1 truncate text-xs text-faint">Recording…</span>
          <IconButton
            label="Cancel recording"
            variant="ghost"
            onClick={recorder.cancel}
            type="button"
          >
            <X className="h-5 w-5" aria-hidden />
          </IconButton>
          <Button type="button" onClick={recorder.stop} aria-label="Stop recording">
            <Square className="h-4 w-4" aria-hidden />
            <span className="hidden sm:inline">Stop</span>
          </Button>
        </div>
      ) : recorder.status === "recorded" ? (
        <div className="flex items-center gap-2">
          <IconButton
            label="Discard recording"
            variant="ghost"
            disabled={isSendingVoice}
            onClick={recorder.reset}
            type="button"
          >
            <X className="h-5 w-5" aria-hidden />
          </IconButton>
          <audio controls src={recorder.previewUrl ?? undefined} className="h-10 min-w-0 flex-1" />
          <Button
            type="button"
            onClick={sendVoice}
            isLoading={isSendingVoice}
            disabled={isSendingVoice}
            aria-label="Send voice message"
          >
            {!isSendingVoice && <Send className="h-4 w-4" aria-hidden />}
            <span className="hidden sm:inline">Send</span>
          </Button>
        </div>
      ) : (
        <div className="flex items-center gap-1.5 sm:gap-2">
          {/* Emoji quick tray */}
          <div ref={emojiRef} className="relative">
            <IconButton
              label="Add an emoji"
              variant="ghost"
              disabled={!hasConversation || isSending}
              onClick={() => setEmojiOpen((v) => !v)}
              type="button"
              aria-expanded={emojiOpen}
            >
              <Smile className="h-5 w-5" aria-hidden />
            </IconButton>
            {emojiOpen ? (
              <div className="absolute bottom-full left-0 z-30 mb-2 flex gap-1 rounded-2xl border border-border bg-surface p-1.5 shadow-elevated animate-scale-in">
                {["😀", "😂", "❤️", "👍", "🙏", "🎉", "😍", "😮"].map((emoji) => (
                  <button
                    key={emoji}
                    type="button"
                    onClick={() => {
                      onDraftChange(draft + emoji);
                      setEmojiOpen(false);
                    }}
                    className="rounded-lg p-1.5 text-lg leading-none transition-transform hover:scale-125"
                    aria-label={`Insert ${emoji}`}
                  >
                    {emoji}
                  </button>
                ))}
              </div>
            ) : null}
          </div>

          {/* "+" attachment menu (replaces the bare paperclip) */}
          <div ref={attachRef} className="relative">
            <IconButton
              label="Add an attachment"
              variant="ghost"
              disabled={!hasConversation || isSending}
              onClick={() => setAttachOpen((v) => !v)}
              type="button"
              aria-expanded={attachOpen}
              aria-haspopup="menu"
            >
              <Plus
                className={cn("h-5 w-5 transition-transform duration-200", attachOpen && "rotate-45")}
                aria-hidden
              />
            </IconButton>

            {attachOpen ? (
              <div
                role="menu"
                className="absolute bottom-full left-0 z-30 mb-2 w-56 overflow-hidden rounded-2xl border border-border bg-surface p-1.5 shadow-elevated animate-scale-in"
              >
                <AttachItem
                  icon={<ImageIcon className="h-[18px] w-[18px]" aria-hidden />}
                  label="Photos & videos"
                  onClick={() => pickWith("image/*,video/*")}
                />
                <AttachItem
                  icon={<Camera className="h-[18px] w-[18px]" aria-hidden />}
                  label="Camera"
                  onClick={() => pickWith("image/*", "environment")}
                />
                <AttachItem
                  icon={<FileText className="h-[18px] w-[18px]" aria-hidden />}
                  label="Document"
                  onClick={() => pickWith("application/pdf,audio/*")}
                />
              </div>
            ) : null}
          </div>

          <input
            className="h-11 min-w-0 flex-1 rounded-full border border-border bg-elevated px-4 text-[15px] text-fg placeholder:text-faint outline-none transition-colors focus:border-brand focus:ring-2 focus:ring-brand-ring disabled:opacity-60"
            disabled={!hasConversation}
            placeholder={
              selectedFile
                ? "Add a caption"
                : hasConversation
                  ? "Type a message…"
                  : "Select a conversation first"
            }
            value={draft}
            onChange={(event) => onDraftChange(event.target.value)}
          />

          {recorder.isSupported && canRecord ? (
            <IconButton
              label="Record a voice message"
              variant="ghost"
              onClick={() => void recorder.start()}
              type="button"
            >
              <Mic className="h-5 w-5" aria-hidden />
            </IconButton>
          ) : null}

          {/* Round accent-gradient send button with glow */}
          <button
            type="submit"
            disabled={!canSend}
            aria-label="Send message"
            className="accent-gradient flex h-11 w-11 shrink-0 items-center justify-center rounded-full text-white shadow-accent-glow transition-all duration-150 outline-none focus-visible:ring-2 focus-visible:ring-brand-ring active:scale-95 disabled:opacity-40 disabled:shadow-none"
          >
            {isSending ? (
              <span className="h-4 w-4 animate-spin rounded-full border-2 border-white/40 border-t-white" aria-hidden />
            ) : (
              <Send className="h-[18px] w-[18px] -translate-x-px" aria-hidden />
            )}
          </button>
        </div>
      )}
    </form>
  );
}

function AttachItem({
  icon,
  label,
  onClick
}: {
  icon: React.ReactNode;
  label: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      role="menuitem"
      onClick={onClick}
      className="flex min-h-11 w-full items-center gap-3 rounded-xl px-3 py-2 text-left text-sm text-fg transition-colors hover:bg-elevated outline-none focus-visible:bg-elevated"
    >
      <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-brand-subtle text-brand-hover">
        {icon}
      </span>
      {label}
    </button>
  );
}

// Elapsed recording time as M:SS.
function formatDuration(ms: number): string {
  const totalSeconds = Math.floor(ms / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}:${seconds.toString().padStart(2, "0")}`;
}
