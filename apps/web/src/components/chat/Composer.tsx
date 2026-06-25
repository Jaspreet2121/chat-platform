import { FormEvent, RefObject, useState } from "react";
import { CornerUpLeft, Mic, Paperclip, Send, Square, X } from "lucide-react";
import { Button, IconButton } from "@/components";
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
    <form className="border-t border-border/70 bg-surface/55 p-3 backdrop-blur-xl sm:p-4" onSubmit={onSubmit}>
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
        <div className="flex items-center gap-2">
          <IconButton
            label="Attach a file"
            variant="ghost"
            disabled={!hasConversation || isSending}
            onClick={onPickFile}
            type="button"
          >
            <Paperclip className="h-5 w-5" aria-hidden />
          </IconButton>

          <input
            className="h-11 min-w-0 flex-1 rounded-xl border border-border bg-elevated px-4 text-fg placeholder:text-faint outline-none transition-colors focus:border-brand focus:ring-2 focus:ring-brand-ring disabled:opacity-60"
            disabled={!hasConversation}
            placeholder={
              selectedFile
                ? "Add a caption"
                : hasConversation
                  ? "Type a message"
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

          <Button type="submit" disabled={!canSend} isLoading={isSending} aria-label="Send message">
            {!isSending && <Send className="h-4 w-4" aria-hidden />}
            <span className="hidden sm:inline">Send</span>
          </Button>
        </div>
      )}
    </form>
  );
}

// Elapsed recording time as M:SS.
function formatDuration(ms: number): string {
  const totalSeconds = Math.floor(ms / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}:${seconds.toString().padStart(2, "0")}`;
}
