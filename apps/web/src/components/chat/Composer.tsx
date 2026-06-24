import { FormEvent, RefObject } from "react";
import { Paperclip, Send, X } from "lucide-react";
import { Button, IconButton } from "@/components";
import { formatFileSize } from "./format";

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
  acceptTypes
}: ComposerProps) {
  const canSend = hasConversation && (Boolean(draft.trim()) || Boolean(selectedFile)) && !isSending;

  return (
    <form className="border-t border-border bg-surface/60 p-3 backdrop-blur sm:p-4" onSubmit={onSubmit}>
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

      <div className="flex items-center gap-2">
        <input
          className="hidden"
          disabled={!hasConversation || isSending}
          onChange={(event) => onFileChange(event.target.files?.[0] ?? null)}
          ref={fileInputRef}
          type="file"
          accept={acceptTypes}
        />
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

        <Button type="submit" disabled={!canSend} isLoading={isSending} aria-label="Send message">
          {!isSending && <Send className="h-4 w-4" aria-hidden />}
          <span className="hidden sm:inline">Send</span>
        </Button>
      </div>
    </form>
  );
}
