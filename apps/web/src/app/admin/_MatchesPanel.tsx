"use client";

import { useCallback, useEffect, useState } from "react";
import { AlertTriangle, Loader2 } from "lucide-react";
import { AdminMatch, ApiRequestError, getAdminMatches, getAdminUserMatches } from "@/lib/api";
import { Avatar, Button, Card, Input } from "@/components";
import { Pager } from "@/app/admin/_Pager";
import { identityTitle } from "@/lib/adminUser";
import { cn } from "@/lib/cn";
import { usePaging } from "@/app/admin/_usePaging";
import {
  REASON_MAX_LENGTH,
  REASON_MIN_LENGTH,
  clearReason,
  loadReason,
  saveReason,
  validateReason
} from "@/lib/matchesReason";

// Match history, for the full list and for one user's tab in the drawer.
//
// THE REASON IS REQUIRED BY THE SERVER on every call — omit it and the API answers 400
// admin.reason_required, reads nothing, and records nothing as having happened. What the console
// adds is only the "once per session-hour" part: prompting on every page turn would train people to
// type "abuse" without reading the box, which is worse than asking less often and having the answer
// mean something.
//
// There is no export button here, and there will not be one. A surface over personal data must not
// have a "give me everything" shape. There is likewise no location anywhere on this screen — the
// admin API has no Nearby endpoint to render.
export function MatchesPanel({ userId }: { userId?: string }) {
  const [reason, setReason] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  // What the SERVER said when it refused a reason the page had accepted — shown in the prompt.
  const [promptError, setPromptError] = useState("");
  const [matches, setMatches] = useState<AdminMatch[]>([]);
  const paging = usePaging(userId ? "matches.user" : "matches");
  const { params: pageParams, setEnvelope } = paging;
  const [q, setQ] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    // Read AFTER mount, not as a lazy initial state: the server render has no sessionStorage, so
    // seeding from it would make the first client render disagree with the server's (prompt vs
    // list) and break hydration.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setReason(loadReason());
  }, []);

  const load = useCallback(
    async (activeReason: string) => {
      setLoading(true);
      setError("");
      try {
        const res = userId
          ? await getAdminUserMatches(userId, activeReason, pageParams)
          : await getAdminMatches(activeReason, { q: q.trim() || undefined, ...pageParams });
        setMatches(res.matches);
        setEnvelope(res);
      } catch (e) {
        // The server is the judge of a reason. If it refuses one this page had accepted — the
        // rules drifted, or a stored reason predates a stricter rule — the answer is the prompt
        // again, with the server's own words, not an error banner over an empty list.
        if (
          e instanceof ApiRequestError &&
          (e.code === "admin.reason_invalid" || e.code === "admin.reason_required")
        ) {
          clearReason();
          setDraft(activeReason);
          setPromptError(e.message);
          setReason(null);
          return;
        }
        setError(e instanceof Error ? e.message : "Could not load matches.");
      } finally {
        setLoading(false);
      }
    },
    [userId, q, pageParams, setEnvelope]
  );

  // `load` changes when the page, the search or the target does. The loading flag is
  // set inside `load`, which the rule reads as a synchronous write in an effect — it is the fetch's
  // own state and there is nowhere else for it to live.
  /* eslint-disable react-hooks/set-state-in-effect */
  useEffect(() => {
    if (reason) void load(reason);
  }, [reason, load]);
  /* eslint-enable react-hooks/set-state-in-effect */

  // Reopen the prompt with the current reason as the draft. The stored one is cleared first, so a
  // closed tab in the meantime cannot silently keep the old reason for the rest of its hour.
  function changeReason() {
    clearReason();
    setDraft(reason ?? "");
    setReason(null);
  }

  function submitReason() {
    const check = validateReason(draft);
    if (!check.ok) return;
    saveReason(check.reason);
    setPromptError("");
    setReason(check.reason);
    setDraft("");
  }

  if (!reason) {
    const check = validateReason(draft);
    return (
      <Card className="p-5">
        <div className="mb-2 flex items-center gap-2">
          <AlertTriangle className="h-4 w-4 text-amber-400" aria-hidden />
          <p className="text-sm font-semibold text-fg">Why are you looking at this?</p>
        </div>
        <p className="mb-4 text-sm text-muted">
          Match history is personal data. Your reason is recorded against your name, this device&apos;s
          IP, and the time — and you&apos;ll be asked again in an hour.
        </p>
        <Input
          value={draft}
          autoComplete="off"
          maxLength={REASON_MAX_LENGTH}
          placeholder="e.g. abuse report #4410, legal request LR-22"
          onChange={(e) => {
            setDraft(e.target.value);
            setPromptError("");
          }}
          onKeyDown={(e) => e.key === "Enter" && submitReason()}
        />
        {/* THE RULE, inline and always visible — and, once something is typed, which part of it
            the draft still fails. The server applies the same rule and answers 400 otherwise. */}
        <p className="mt-2 text-xs text-faint">
          At least {REASON_MIN_LENGTH} characters and two real words — a ticket, a case, a name.
          Repeated characters are not a reason.
        </p>
        {promptError ? <p className="mt-1 text-xs text-danger">{promptError}</p> : null}
        <div className="mt-3 flex items-center justify-between gap-3">
          <p className="text-xs text-faint">
            {draft.trim() === ""
              ? ""
              : check.ok
                ? `${check.reason.length}/${REASON_MAX_LENGTH}`
                : `Not yet: ${check.why}.`}
          </p>
          <Button size="sm" onClick={submitReason} disabled={!check.ok}>
            Continue
          </Button>
        </div>
      </Card>
    );
  }

  return (
    <div>
      <div className="mb-3 flex flex-wrap items-center gap-2">
        {!userId ? (
          <Input
            className="h-9 w-64"
            value={q}
            placeholder="Search by name or user id…"
            onChange={(e) => setQ(e.target.value)}
            onKeyDown={(e) => {
              if (e.key !== "Enter") return;
              // A new search is a new list: page 7 of the old one is nowhere in it.
              paging.reset();
              void load(reason);
            }}
          />
        ) : null}
        {/* What the audit row already holds, and a way to say something different. "Change"
            reopens the prompt with the current text; the hour starts again from the new reason. */}
        <p className="ml-auto flex items-center gap-1.5 text-xs text-faint" title={reason}>
          <span>
            Reason on record: <span className="text-muted">“{reason}”</span>
          </span>
          <span aria-hidden>·</span>
          <button
            type="button"
            onClick={changeReason}
            className="text-brand-hover underline-offset-2 hover:underline"
          >
            Change
          </button>
        </p>
      </div>

      {error ? <Card className="border-danger/40 p-4 text-sm text-danger">{error}</Card> : null}

      {matches.length === 0 && !loading && !error ? (
        <Card className="p-8 text-center text-sm text-muted">
          No matches.
          {/* Said out loud, because the alternative reading — "we lost them" — is worse. */}
          <span className="mt-1 block text-xs text-faint">
            Unmatching deletes the record, so only current matches appear here.
          </span>
        </Card>
      ) : (
        <Card className="divide-y divide-border p-0">
          {matches.map((m) => (
            <div key={m.id} className="flex items-center gap-3 p-3">
              <MatchPhoto
                id={m.user_low_id}
                url={m.user_low_avatar_url}
                name={identityTitle({ display_name: m.user_low_name, username: m.user_low_username })}
              />
              <MatchPhoto
                id={m.user_high_id}
                url={m.user_high_avatar_url}
                name={identityTitle({ display_name: m.user_high_name, username: m.user_high_username })}
              />
              <div className="min-w-0 flex-1">
                <p className="truncate text-sm text-fg">
                  <span title={m.user_low_id}>
                    {identityTitle({ display_name: m.user_low_name, username: m.user_low_username })}
                  </span>
                  <span className="text-faint"> · </span>
                  <span title={m.user_high_id}>
                    {identityTitle({ display_name: m.user_high_name, username: m.user_high_username })}
                  </span>
                </p>
                <p className="truncate text-xs text-faint tabular-nums">
                  matched {m.matched_at}
                  {m.unmatched_at ? ` · unmatched ${m.unmatched_at}` : ""}
                </p>
              </div>
              <span
                className={cn(
                  "shrink-0 rounded-full px-2 py-0.5 text-xs font-medium",
                  m.active ? "bg-success/10 text-success" : "bg-elevated text-muted"
                )}
              >
                {m.active ? "active" : "unmatched"}
              </span>
            </div>
          ))}
        </Card>
      )}

      {loading ? (
        <div className="mt-3 flex justify-center text-muted">
          <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
        </div>
      ) : (
        <Pager paging={paging} disabled={loading} />
      )}
    </div>
  );
}

// A presigned avatar when there is one, the initials tile otherwise. A failed presign arrives as
// null and simply shows the tile — never a broken image.
function MatchPhoto({ id, url, name }: { id: string; url?: string | null; name: string }) {
  return <Avatar id={id} name={name} size="sm" imageUrl={url ?? undefined} />;
}
