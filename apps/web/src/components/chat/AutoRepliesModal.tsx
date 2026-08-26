"use client";

import { useCallback, useEffect, useState } from "react";
import { Loader2, X } from "lucide-react";
import { Button, Card } from "@/components";
import {
  AUTO_REPLY_BODY_MAX,
  getAutoReplies,
  searchUsers,
  updateAutoReplies,
  type AutoReplies,
  type AutoReplyAudience,
  type AutoReplyAway,
  type AutoReplyGreeting,
  type AutoReplyRange,
  type UserProfile
} from "@/lib/api";
import {
  AUDIENCE_OPTIONS,
  VALIDATION_COPY,
  WEEKDAYS,
  buildAway,
  buildGreeting,
  defaultSchedule,
  greetingWithDefaults,
  validateAway,
  validateGreeting,
  withDefaults
} from "@/lib/autoReplies";

export type AutoRepliesModalProps = {
  onClose: () => void;
  /** Bumped by the realtime `auto_replies_changed` event to force a refetch. */
  refreshNonce?: number;
};

export function AutoRepliesModal({ onClose, refreshNonce = 0 }: AutoRepliesModalProps) {
  const [away, setAway] = useState<AutoReplyAway | null>(null);
  const [greeting, setGreeting] = useState<AutoReplyGreeting | null>(null);
  const [loadError, setLoadError] = useState("");
  const [savingBlock, setSavingBlock] = useState<"away" | "greeting" | "">("");
  const [saveError, setSaveError] = useState("");
  const [savedBlock, setSavedBlock] = useState<"away" | "greeting" | "">("");

  const apply = useCallback((settings: AutoReplies) => {
    setAway(withDefaults(settings.away));
    setGreeting(greetingWithDefaults(settings.greeting));
  }, []);

  // Load, and reload whenever another device changes the settings (the event payload is empty, so
  // there is nothing to merge — refetching is the only correct response).
  useEffect(() => {
    let active = true;
    getAutoReplies()
      .then((settings) => active && apply(settings))
      .catch(() => active && setLoadError("Couldn't load your automated replies."));
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

  async function save(block: "away" | "greeting") {
    if (!away || !greeting) return;

    const problem = block === "away" ? validateAway(away) : validateGreeting(greeting);
    if (problem) {
      setSaveError(VALIDATION_COPY[problem]);
      return;
    }

    setSavingBlock(block);
    setSaveError("");
    setSavedBlock("");
    try {
      // Send ONLY the edited block — the server replaces what it receives and leaves the rest alone.
      const payload =
        block === "away" ? { away: buildAway(away) } : { greeting: buildGreeting(greeting) };
      apply(await updateAutoReplies(payload));
      setSavedBlock(block);
    } catch (error) {
      setSaveError(error instanceof Error ? error.message : "Couldn't save that.");
    } finally {
      setSavingBlock("");
    }
  }

  const schedule = away?.schedule ?? null;

  function setRange(index: number, patch: Partial<AutoReplyRange>) {
    setAway((current) => {
      if (!current) return current;
      const base = current.schedule ?? defaultSchedule();
      return {
        ...current,
        schedule: {
          ...base,
          ranges: base.ranges.map((range, i) => (i === index ? { ...range, ...patch } : range))
        }
      };
    });
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm animate-fade-in">
      <button type="button" aria-label="Close" onClick={onClose} className="absolute inset-0" />
      <Card className="relative flex max-h-[min(88dvh,46rem)] w-full max-w-lg flex-col overflow-hidden p-0 animate-scale-in">
        <header className="flex items-center justify-between border-b border-border px-4 py-3">
          <div>
            <h2 className="text-sm font-semibold text-fg">Automated replies</h2>
            <p className="text-xs text-faint">Replies sent for you when you can&apos;t answer</p>
          </div>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close automated replies"
            className="rounded-lg p-2 text-muted transition-colors hover:bg-elevated hover:text-fg"
          >
            <X className="h-4 w-4" aria-hidden />
          </button>
        </header>

        <div className="min-h-0 flex-1 space-y-4 overflow-y-auto p-4">
          {/* The engine reads message text to decide, which it cannot do in an encrypted chat. Say so
              rather than letting a user wonder why a secret chat never auto-replies. */}
          <p className="rounded-lg bg-brand-subtle px-3 py-2 text-[11px] leading-relaxed text-brand-hover">
            Automated replies work in one-to-one chats that aren&apos;t end-to-end encrypted. Secret
            chats are never answered automatically.
          </p>

          {loadError ? (
            <p className="rounded-lg bg-danger/10 px-3 py-2 text-xs text-danger">{loadError}</p>
          ) : null}
          {saveError ? (
            <p className="rounded-lg bg-danger/10 px-3 py-2 text-xs text-danger">{saveError}</p>
          ) : null}

          {!away || !greeting ? (
            !loadError ? (
              <div className="flex justify-center py-10">
                <Loader2 className="h-5 w-5 animate-spin text-muted" aria-hidden />
              </div>
            ) : null
          ) : (
            <>
              {/* ---- Away ---- */}
              <section className="space-y-3 rounded-xl border border-border bg-elevated p-3">
                <SwitchRow
                  label="Away message"
                  hint="Replies once a day to anyone who messages while you're away."
                  checked={away.enabled}
                  onChange={(enabled) => setAway({ ...away, enabled })}
                />

                <BodyField
                  value={away.body ?? ""}
                  placeholder="I'm away right now — I'll reply when I'm back."
                  onChange={(body) => setAway({ ...away, body })}
                />

                <AudienceField
                  value={away.audience}
                  exceptIds={away.except_ids ?? []}
                  onAudience={(audience) => setAway({ ...away, audience })}
                  onExceptIds={(except_ids) => setAway({ ...away, except_ids })}
                />

                <div className="space-y-2">
                  <span className="block text-xs font-medium text-fg">When</span>
                  <div className="flex gap-2">
                    {(["always", "custom"] as const).map((mode) => (
                      <button
                        key={mode}
                        type="button"
                        onClick={() =>
                          setAway({
                            ...away,
                            mode,
                            schedule: mode === "custom" ? (away.schedule ?? defaultSchedule()) : null
                          })
                        }
                        className={`rounded-lg px-3 py-1.5 text-xs transition-colors ${
                          away.mode === mode ? "bg-brand text-white" : "bg-surface text-muted hover:text-fg"
                        }`}
                      >
                        {mode === "always" ? "Always" : "On a schedule"}
                      </button>
                    ))}
                  </div>

                  {away.mode === "custom" && schedule ? (
                    <div className="space-y-3 rounded-lg border border-border bg-surface p-3">
                      <label className="flex items-center justify-between gap-3 text-xs">
                        <span className="text-fg">Time zone</span>
                        <input
                          className="min-w-0 flex-1 rounded-lg border border-border bg-elevated px-2 py-1.5 text-right text-xs text-fg outline-none focus:border-brand focus:ring-2 focus:ring-brand-ring"
                          value={schedule.timezone}
                          spellCheck={false}
                          onChange={(event) =>
                            setAway({
                              ...away,
                              schedule: { ...schedule, timezone: event.target.value }
                            })
                          }
                        />
                      </label>

                      {schedule.ranges.map((range, index) => (
                        <div key={index} className="space-y-2 border-t border-border/60 pt-2 first:border-0 first:pt-0">
                          <div className="flex flex-wrap gap-1">
                            {WEEKDAYS.map((day) => {
                              const on = range.days.includes(day.value);
                              return (
                                <button
                                  key={day.value}
                                  type="button"
                                  aria-pressed={on}
                                  onClick={() =>
                                    setRange(index, {
                                      days: on
                                        ? range.days.filter((d) => d !== day.value)
                                        : [...range.days, day.value].sort((a, b) => a - b)
                                    })
                                  }
                                  className={`rounded-md px-2 py-1 text-[11px] transition-colors ${
                                    on ? "bg-brand text-white" : "bg-elevated text-muted hover:text-fg"
                                  }`}
                                >
                                  {day.label}
                                </button>
                              );
                            })}
                          </div>
                          <div className="flex items-center gap-2 text-xs text-muted">
                            <input
                              type="time"
                              aria-label="Start time"
                              value={range.start}
                              onChange={(event) => setRange(index, { start: event.target.value })}
                              className="rounded-lg border border-border bg-elevated px-2 py-1.5 text-fg outline-none focus:border-brand"
                            />
                            <span>to</span>
                            <input
                              type="time"
                              aria-label="End time"
                              value={range.end}
                              onChange={(event) => setRange(index, { end: event.target.value })}
                              className="rounded-lg border border-border bg-elevated px-2 py-1.5 text-fg outline-none focus:border-brand"
                            />
                          </div>
                          {range.start > range.end ? (
                            <p className="text-[11px] text-faint">This window runs overnight.</p>
                          ) : null}
                        </div>
                      ))}
                    </div>
                  ) : null}
                </div>

                <SaveRow
                  saving={savingBlock === "away"}
                  saved={savedBlock === "away"}
                  onSave={() => void save("away")}
                />
              </section>

              {/* ---- Greeting ---- */}
              <section className="space-y-3 rounded-xl border border-border bg-elevated p-3">
                <SwitchRow
                  label="Greeting"
                  hint="Sent the first time someone messages you, and again after a quiet spell."
                  checked={greeting.enabled}
                  onChange={(enabled) => setGreeting({ ...greeting, enabled })}
                />

                <BodyField
                  value={greeting.body ?? ""}
                  placeholder="Hi! Thanks for the message — I'll get back to you shortly."
                  onChange={(body) => setGreeting({ ...greeting, body })}
                />

                <AudienceField
                  value={greeting.audience}
                  exceptIds={greeting.except_ids ?? []}
                  onAudience={(audience) => setGreeting({ ...greeting, audience })}
                  onExceptIds={(except_ids) => setGreeting({ ...greeting, except_ids })}
                />

                <label className="flex items-center justify-between gap-3 text-xs">
                  <span className="text-fg">Send again after</span>
                  <span className="flex items-center gap-2">
                    <input
                      type="number"
                      min={1}
                      max={365}
                      value={greeting.resend_after_days}
                      onChange={(event) =>
                        setGreeting({
                          ...greeting,
                          resend_after_days: Number.parseInt(event.target.value, 10) || 0
                        })
                      }
                      className="w-20 rounded-lg border border-border bg-surface px-2 py-1.5 text-right text-xs text-fg outline-none focus:border-brand focus:ring-2 focus:ring-brand-ring"
                    />
                    <span className="text-muted">days</span>
                  </span>
                </label>

                <SaveRow
                  saving={savingBlock === "greeting"}
                  saved={savedBlock === "greeting"}
                  onSave={() => void save("greeting")}
                />
              </section>
            </>
          )}
        </div>
      </Card>
    </div>
  );
}

function SwitchRow({
  label,
  hint,
  checked,
  onChange
}: {
  label: string;
  hint: string;
  checked: boolean;
  onChange: (next: boolean) => void;
}) {
  return (
    <div className="flex items-start justify-between gap-3">
      <span className="min-w-0">
        <span className="block text-sm font-medium text-fg">{label}</span>
        <span className="block text-[11px] leading-relaxed text-faint">{hint}</span>
      </span>
      <button
        type="button"
        role="switch"
        aria-checked={checked}
        aria-label={label}
        onClick={() => onChange(!checked)}
        className={`relative mt-0.5 h-6 w-11 shrink-0 rounded-full transition-colors ${
          checked ? "accent-gradient" : "bg-border-strong"
        }`}
      >
        <span
          className={`absolute top-0.5 h-5 w-5 rounded-full bg-white shadow-subtle transition-all ${
            checked ? "left-[22px]" : "left-0.5"
          }`}
        />
      </button>
    </div>
  );
}

function BodyField({
  value,
  placeholder,
  onChange
}: {
  value: string;
  placeholder: string;
  onChange: (next: string) => void;
}) {
  const remaining = AUTO_REPLY_BODY_MAX - value.length;
  return (
    <div className="space-y-1">
      <textarea
        rows={3}
        value={value}
        placeholder={placeholder}
        maxLength={AUTO_REPLY_BODY_MAX}
        onChange={(event) => onChange(event.target.value)}
        className="w-full resize-none rounded-lg border border-border bg-surface px-3 py-2 text-sm text-fg placeholder:text-faint outline-none focus:border-brand focus:ring-2 focus:ring-brand-ring"
      />
      <p className={`text-right text-[11px] ${remaining < 25 ? "text-danger" : "text-faint"}`}>
        {remaining} left
      </p>
    </div>
  );
}

function AudienceField({
  value,
  exceptIds,
  onAudience,
  onExceptIds
}: {
  value: AutoReplyAudience;
  exceptIds: string[];
  onAudience: (next: AutoReplyAudience) => void;
  onExceptIds: (next: string[]) => void;
}) {
  // The exclusion list is arbitrary user ids, so the picker is a SEARCH (there is no bulk contact
  // list to page through, and search is the same directory lookup the rest of the app uses).
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<UserProfile[]>([]);
  const [searching, setSearching] = useState(false);
  // Names for already-excluded ids, so a saved list renders as people rather than raw uuids.
  const [names, setNames] = useState<Record<string, string>>({});

  const remember = useCallback((users: UserProfile[]) => {
    setNames((current) => {
      const next = { ...current };
      for (const user of users) {
        if (user.display_name?.trim()) next[user.user_id] = user.display_name.trim();
      }
      return next;
    });
  }, []);

  // Debounced search — the endpoint is rate-limited server-side as an enumeration oracle. Every
  // setState happens inside the timer callback (never synchronously in the effect body), so this
  // stays a subscribe-to-an-external-system effect rather than a cascading render.
  useEffect(() => {
    const term = query.trim();
    const shouldSearch = value === "except" && term.length >= 2;

    const handle = window.setTimeout(
      () => {
        if (!shouldSearch) {
          setResults([]);
          setSearching(false);
          return;
        }

        setSearching(true);
        searchUsers(term)
          .then((response) => {
            setResults(response.users ?? []);
            remember(response.users ?? []);
          })
          .catch(() => setResults([]))
          .finally(() => setSearching(false));
      },
      shouldSearch ? 300 : 0
    );

    return () => window.clearTimeout(handle);
  }, [query, value, remember]);

  return (
    <div className="space-y-2">
      <label className="flex items-center justify-between gap-3 text-xs">
        <span className="text-fg">Reply to</span>
        <select
          value={value}
          onChange={(event) => onAudience(event.target.value as AutoReplyAudience)}
          className="rounded-lg border border-border bg-surface px-2 py-1.5 text-xs text-fg outline-none focus:border-brand focus:ring-2 focus:ring-brand-ring"
        >
          {AUDIENCE_OPTIONS.map((option) => (
            <option key={option.value} value={option.value}>
              {option.label}
            </option>
          ))}
        </select>
      </label>

      {value === "except" ? (
        <div className="space-y-2 rounded-lg border border-border bg-surface p-2">
          {exceptIds.length > 0 ? (
            <ul className="flex flex-wrap gap-1">
              {exceptIds.map((id) => (
                <li
                  key={id}
                  className="flex items-center gap-1 rounded-full bg-brand-subtle px-2 py-1 text-[11px] text-brand-hover"
                >
                  <span className="max-w-[10rem] truncate">{names[id] ?? `#${id.slice(0, 8)}`}</span>
                  <button
                    type="button"
                    aria-label={`Stop excluding ${names[id] ?? id}`}
                    onClick={() => onExceptIds(exceptIds.filter((other) => other !== id))}
                    className="rounded-full p-0.5 hover:bg-brand/20"
                  >
                    <X className="h-3 w-3" aria-hidden />
                  </button>
                </li>
              ))}
            </ul>
          ) : (
            <p className="px-1 text-[11px] text-faint">No one excluded yet.</p>
          )}

          <input
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Search people to exclude…"
            className="w-full rounded-lg border border-border bg-elevated px-2 py-1.5 text-xs text-fg placeholder:text-faint outline-none focus:border-brand focus:ring-2 focus:ring-brand-ring"
          />

          {searching ? (
            <p className="px-1 text-[11px] text-faint">Searching…</p>
          ) : results.length > 0 ? (
            <ul className="max-h-32 overflow-y-auto">
              {results
                .filter((user) => !exceptIds.includes(user.user_id))
                .map((user) => (
                  <li key={user.user_id}>
                    <button
                      type="button"
                      onClick={() => {
                        onExceptIds([...exceptIds, user.user_id]);
                        setQuery("");
                      }}
                      className="w-full truncate rounded-md px-2 py-1.5 text-left text-xs text-fg hover:bg-elevated"
                    >
                      {user.display_name?.trim() || `#${user.user_id.slice(0, 8)}`}
                    </button>
                  </li>
                ))}
            </ul>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

function SaveRow({
  saving,
  saved,
  onSave
}: {
  saving: boolean;
  saved: boolean;
  onSave: () => void;
}) {
  return (
    <div className="flex items-center justify-end gap-3">
      {saved ? <span className="text-[11px] text-brand">Saved</span> : null}
      <Button type="button" size="sm" onClick={onSave} isLoading={saving}>
        Save
      </Button>
    </div>
  );
}
