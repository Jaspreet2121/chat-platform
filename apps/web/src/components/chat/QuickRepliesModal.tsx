"use client";

import { useCallback, useEffect, useState } from "react";
import { GripVertical, Loader2, Pencil, Plus, Trash2, X } from "lucide-react";
import { Button, Card } from "@/components";
import {
  ApiRequestError,
  QUICK_REPLY_BODY_MAX,
  QUICK_REPLY_MAX,
  createQuickReply,
  deleteQuickReply,
  listQuickReplies,
  reorderQuickReplies,
  updateQuickReply,
  type QuickReply
} from "@/lib/api";
import { quickReplyError, validateQuickReply } from "@/lib/quickReplies";

export type QuickRepliesModalProps = {
  onClose: () => void;
  /** Bumped by the realtime `quick_replies_changed` event to force a refetch. */
  refreshNonce?: number;
  /** Lets the page keep its composer palette in sync after a local edit. */
  onChanged?: (replies: QuickReply[]) => void;
};

type Draft = { id: string | null; shortcut: string; body: string };

const EMPTY: Draft = { id: null, shortcut: "", body: "" };

export function QuickRepliesModal({ onClose, refreshNonce = 0, onChanged }: QuickRepliesModalProps) {
  const [replies, setReplies] = useState<QuickReply[] | null>(null);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [dragId, setDragId] = useState<string | null>(null);

  const apply = useCallback(
    (next: QuickReply[]) => {
      setReplies(next);
      onChanged?.(next);
    },
    [onChanged]
  );

  useEffect(() => {
    let active = true;
    listQuickReplies()
      .then((response) => active && apply(response.quick_replies ?? []))
      .catch(() => active && setError("Couldn't load your quick replies."));
    return () => {
      active = false;
    };
  }, [apply, refreshNonce]);

  useEffect(() => {
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape") onClose();
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  async function save() {
    if (!draft) return;

    const problem = validateQuickReply(draft.shortcut, draft.body);
    if (problem) {
      setError(problem);
      return;
    }

    setBusy(true);
    setError("");
    try {
      const shortcut = draft.shortcut.trim().toLowerCase();
      if (draft.id) {
        const updated = await updateQuickReply(draft.id, { shortcut, body: draft.body });
        apply((replies ?? []).map((row) => (row.id === updated.id ? updated : row)));
      } else {
        const created = await createQuickReply({ shortcut, body: draft.body });
        apply([...(replies ?? []), created]);
      }
      setDraft(null);
    } catch (saveError) {
      // quick_reply.reserved is a 409 the user can actually fix — name the conflict plainly.
      setError(
        saveError instanceof ApiRequestError
          ? quickReplyError(saveError.code, saveError.message)
          : "Couldn't save that quick reply."
      );
    } finally {
      setBusy(false);
    }
  }

  async function remove(id: string) {
    setBusy(true);
    setError("");
    try {
      await deleteQuickReply(id);
      apply((replies ?? []).filter((row) => row.id !== id));
    } catch {
      setError("Couldn't delete that quick reply.");
    } finally {
      setBusy(false);
    }
  }

  // Drag-to-reorder: reorder locally for an instant result, then persist the new id order. The
  // server re-lists, and that response is what we keep (it owns `position`).
  async function persistOrder(next: QuickReply[]) {
    apply(next);
    try {
      const response = await reorderQuickReplies(next.map((row) => row.id));
      apply(response.quick_replies ?? next);
    } catch {
      setError("Couldn't save the new order.");
    }
  }

  function onDrop(targetId: string) {
    const list = replies ?? [];
    if (!dragId || dragId === targetId) return;

    const from = list.findIndex((row) => row.id === dragId);
    const to = list.findIndex((row) => row.id === targetId);
    if (from < 0 || to < 0) return;

    const next = [...list];
    const [moved] = next.splice(from, 1);
    next.splice(to, 0, moved);
    setDragId(null);
    void persistOrder(next);
  }

  const atLimit = (replies?.length ?? 0) >= QUICK_REPLY_MAX;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm animate-fade-in">
      <button type="button" aria-label="Close" onClick={onClose} className="absolute inset-0" />
      <Card className="relative flex max-h-[min(88dvh,44rem)] w-full max-w-lg flex-col overflow-hidden p-0 animate-scale-in">
        <header className="flex items-center justify-between border-b border-border px-4 py-3">
          <div>
            <h2 className="text-sm font-semibold text-fg">Quick replies</h2>
            <p className="text-xs text-faint">Type / in a chat to use them</p>
          </div>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close quick replies"
            className="rounded-lg p-2 text-muted transition-colors hover:bg-elevated hover:text-fg"
          >
            <X className="h-4 w-4" aria-hidden />
          </button>
        </header>

        <div className="min-h-0 flex-1 space-y-3 overflow-y-auto p-4">
          {error ? (
            <p className="rounded-lg bg-danger/10 px-3 py-2 text-xs text-danger">{error}</p>
          ) : null}

          {replies === null ? (
            <div className="flex justify-center py-10">
              <Loader2 className="h-5 w-5 animate-spin text-muted" aria-hidden />
            </div>
          ) : (
            <>
              {replies.length === 0 && !draft ? (
                <p className="rounded-xl border border-dashed border-border px-3 py-8 text-center text-sm text-faint">
                  No quick replies yet. Add one to send it with a shortcut.
                </p>
              ) : null}

              <ul className="space-y-2">
                {replies.map((reply) => (
                  <li
                    key={reply.id}
                    draggable
                    onDragStart={() => setDragId(reply.id)}
                    onDragEnd={() => setDragId(null)}
                    onDragOver={(event) => event.preventDefault()}
                    onDrop={() => onDrop(reply.id)}
                    className={`flex items-start gap-2 rounded-xl border border-border bg-elevated p-3 ${
                      dragId === reply.id ? "opacity-50" : ""
                    }`}
                  >
                    <span
                      className="mt-0.5 cursor-grab text-faint active:cursor-grabbing"
                      aria-hidden
                      title="Drag to reorder"
                    >
                      <GripVertical className="h-4 w-4" />
                    </span>
                    <span className="min-w-0 flex-1">
                      <span className="block text-sm font-medium text-fg">/{reply.shortcut}</span>
                      <span className="block truncate text-xs text-muted">{reply.body}</span>
                    </span>
                    <button
                      type="button"
                      aria-label={`Edit /${reply.shortcut}`}
                      disabled={busy}
                      onClick={() =>
                        setDraft({ id: reply.id, shortcut: reply.shortcut, body: reply.body })
                      }
                      className="rounded-lg p-1.5 text-muted transition-colors hover:bg-surface hover:text-fg"
                    >
                      <Pencil className="h-4 w-4" aria-hidden />
                    </button>
                    <button
                      type="button"
                      aria-label={`Delete /${reply.shortcut}`}
                      disabled={busy}
                      onClick={() => void remove(reply.id)}
                      className="rounded-lg p-1.5 text-muted transition-colors hover:bg-danger/10 hover:text-danger"
                    >
                      <Trash2 className="h-4 w-4" aria-hidden />
                    </button>
                  </li>
                ))}
              </ul>

              {draft ? (
                <div className="space-y-2 rounded-xl border border-brand/40 bg-surface p-3">
                  <label className="block space-y-1">
                    <span className="text-xs font-medium text-fg">Shortcut</span>
                    <span className="flex items-center gap-1">
                      <span className="text-sm text-faint">/</span>
                      <input
                        value={draft.shortcut}
                        onChange={(event) =>
                          setDraft({ ...draft, shortcut: event.target.value.toLowerCase() })
                        }
                        placeholder="thanks"
                        maxLength={25}
                        className="min-w-0 flex-1 rounded-lg border border-border bg-elevated px-2 py-1.5 text-sm text-fg placeholder:text-faint outline-none focus:border-brand focus:ring-2 focus:ring-brand-ring"
                      />
                    </span>
                    <span className="block text-[11px] text-faint">
                      Lowercase letters, numbers and underscores.
                    </span>
                  </label>

                  <label className="block space-y-1">
                    <span className="text-xs font-medium text-fg">Message</span>
                    <textarea
                      rows={3}
                      value={draft.body}
                      maxLength={QUICK_REPLY_BODY_MAX}
                      onChange={(event) => setDraft({ ...draft, body: event.target.value })}
                      placeholder="Thanks for reaching out!"
                      className="w-full resize-none rounded-lg border border-border bg-elevated px-3 py-2 text-sm text-fg placeholder:text-faint outline-none focus:border-brand focus:ring-2 focus:ring-brand-ring"
                    />
                  </label>

                  <div className="flex justify-end gap-2">
                    <Button type="button" size="sm" variant="ghost" onClick={() => setDraft(null)}>
                      Cancel
                    </Button>
                    <Button type="button" size="sm" isLoading={busy} onClick={() => void save()}>
                      Save
                    </Button>
                  </div>
                </div>
              ) : (
                <Button
                  type="button"
                  fullWidth
                  variant="ghost"
                  disabled={atLimit}
                  onClick={() => {
                    setError("");
                    setDraft(EMPTY);
                  }}
                  leftIcon={<Plus className="h-4 w-4" aria-hidden />}
                >
                  {atLimit ? `Limit reached (${QUICK_REPLY_MAX})` : "Add a quick reply"}
                </Button>
              )}
            </>
          )}
        </div>
      </Card>
    </div>
  );
}
