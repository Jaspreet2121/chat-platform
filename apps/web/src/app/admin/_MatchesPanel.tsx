"use client";

import { useCallback, useEffect, useState } from "react";
import { AlertTriangle, HeartHandshake, Loader2 } from "lucide-react";
import { AdminMatch, getAdminMatches, getAdminUserMatches } from "@/lib/api";
import { Button, Card, Input } from "@/components";
import { Pager } from "@/app/admin/_Pager";
import { identityTitle } from "@/lib/adminUser";
import { usePaging } from "@/app/admin/_usePaging";
import {
  REASON_MAX_LENGTH,
  REASON_MIN_LENGTH,
  loadReason,
  reasonIsValid,
  saveReason
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

  function submitReason() {
    const trimmed = draft.trim();
    if (!reasonIsValid(trimmed)) return;
    saveReason(trimmed);
    setReason(trimmed);
    setDraft("");
  }

  if (!reason) {
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
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && submitReason()}
        />
        <div className="mt-3 flex items-center justify-between gap-3">
          <p className="text-xs text-faint">
            {draft.trim().length < REASON_MIN_LENGTH
              ? `At least ${REASON_MIN_LENGTH} characters.`
              : `${draft.trim().length}/${REASON_MAX_LENGTH}`}
          </p>
          <Button size="sm" onClick={submitReason} disabled={!reasonIsValid(draft)}>
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
        <p className="ml-auto text-xs text-faint" title={reason}>
          Logged as: “{reason}”
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
              <HeartHandshake className="h-4 w-4 shrink-0 text-faint" aria-hidden />
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
              </div>
              <span className="shrink-0 text-xs text-faint tabular-nums">{m.matched_at}</span>
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
