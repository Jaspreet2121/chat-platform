"use client";

import { useCallback, useEffect, useState } from "react";
import { ArrowLeft, ChevronRight, Loader2, Lock, Search, Unlock } from "lucide-react";
import {
  AdminConversationMessages,
  AdminUser,
  AdminUserConversation,
  getAdminConversationMessages,
  getAdminUserConversations,
  getAdminUsers
} from "@/lib/api";
import { Avatar, Card } from "@/components";
import { cn } from "@/lib/cn";

function shortId(id?: string | null) {
  return id ? `#${id.slice(0, 8)}` : "—";
}

function formatPhone(raw?: string | null) {
  if (!raw) return "";
  const digits = raw.replace(/\D/g, "");
  if (digits.length === 12 && digits.startsWith("91")) {
    return `+91 ${digits.slice(2, 7)} ${digits.slice(7)}`;
  }
  return raw.startsWith("+") ? raw : `+${digits}`;
}

// A user's display label: name → formatted phone → email → (falls back to id at the call site).
function userLabel(u: AdminUser) {
  return u.display_name?.trim() || formatPhone(u.phone_number) || u.email?.trim() || "";
}

// A conversation's title in a given user's list: the direct peer's name, else the group title, else a
// clean fallback (no raw ids as the main label).
function convLabel(c: AdminUserConversation) {
  if (c.type === "direct") return c.other_name?.trim() || "Direct message";
  return c.title?.trim() || "Group chat";
}

function listTime(ts?: string | null) {
  if (!ts) return "";
  const d = new Date(ts);
  if (Number.isNaN(d.getTime())) return "";
  const now = new Date();
  const sameDay =
    d.getFullYear() === now.getFullYear() &&
    d.getMonth() === now.getMonth() &&
    d.getDate() === now.getDate();
  return sameDay
    ? d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" })
    : d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

function fmt(ts?: string | null) {
  if (!ts) return "";
  const d = new Date(ts);
  return Number.isNaN(d.getTime()) ? "" : d.toLocaleString();
}

function Centered({ children }: { children: React.ReactNode }) {
  return <div className="flex items-center justify-center gap-2 py-16 text-muted">{children}</div>;
}

export default function AdminContentPage() {
  // Drill-down: users (L1) → the selected user's conversations (L2) → a conversation's messages (L3).
  const [user, setUser] = useState<AdminUser | null>(null);
  const [conv, setConv] = useState<AdminUserConversation | null>(null);

  if (conv && user) {
    return <MessagesView user={user} conv={conv} onBack={() => setConv(null)} />;
  }
  if (user) {
    return <UserConversations user={user} onOpen={setConv} onBack={() => setUser(null)} />;
  }
  return <UsersList onOpen={setUser} />;
}

// --- Level 1: users -------------------------------------------------------------------------------
function UsersList({ onOpen }: { onOpen: (u: AdminUser) => void }) {
  const [users, setUsers] = useState<AdminUser[]>([]);
  const [q, setQ] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const res = await getAdminUsers({ q: q.trim() || undefined });
      setUsers(res.users);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load users");
    } finally {
      setLoading(false);
    }
  }, [q]);

  useEffect(() => {
    void load();
  }, [load]);

  return (
    <div className="mx-auto max-w-4xl animate-fade-in">
      <h2 className="text-xl font-semibold text-fg">Content viewer</h2>
      <p className="mb-5 text-sm text-muted">
        Pick a user to see who they&apos;ve chatted with. Full message content requires the{" "}
        <span className="font-medium text-fg">content.read</span> permission (root); otherwise messages
        are masked. Every unmasked read is audited.
      </p>

      <div className="relative mb-4 max-w-sm">
        <Search
          className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-faint"
          aria-hidden
        />
        <input
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder="Search by phone or email…"
          className="h-10 w-full rounded-lg border border-border bg-elevated pl-9 pr-3 text-sm text-fg placeholder:text-faint outline-none focus:border-brand focus:ring-2 focus:ring-brand-ring"
        />
      </div>

      {error && <Card className="mb-4 border-danger/40 p-4 text-sm text-danger">{error}</Card>}

      {loading ? (
        <Centered>
          <Loader2 className="h-5 w-5 animate-spin" aria-hidden /> Loading users…
        </Centered>
      ) : (
        <Card className="divide-y divide-border/50 p-0">
          {users.map((u) => {
            const label = userLabel(u);
            return (
              <button
                key={u.user_id}
                type="button"
                onClick={() => onOpen(u)}
                className="flex w-full items-center gap-3 px-3 py-2.5 text-left transition-colors hover:bg-elevated"
              >
                <Avatar id={u.user_id} name={label || u.user_id} size="md" />
                <div className="min-w-0 flex-1">
                  <p
                    className={cn(
                      "truncate text-sm",
                      label ? "font-medium text-fg" : "font-mono text-muted"
                    )}
                  >
                    {label || shortId(u.user_id)}
                  </p>
                  <p className="truncate text-xs text-faint">
                    {u.role ?? "user"}
                    {u.phone_number && formatPhone(u.phone_number) !== label
                      ? ` · ${formatPhone(u.phone_number)}`
                      : ""}
                  </p>
                </div>
                <ChevronRight className="h-4 w-4 shrink-0 text-faint" aria-hidden />
              </button>
            );
          })}
          {users.length === 0 && (
            <div className="p-8 text-center text-sm text-muted">No users.</div>
          )}
        </Card>
      )}
    </div>
  );
}

// --- Level 2: the user's conversations ------------------------------------------------------------
function UserConversations({
  user,
  onOpen,
  onBack
}: {
  user: AdminUser;
  onOpen: (c: AdminUserConversation) => void;
  onBack: () => void;
}) {
  const [rows, setRows] = useState<AdminUserConversation[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const label = userLabel(user) || shortId(user.user_id);

  useEffect(() => {
    let active = true;
    setLoading(true);
    setError("");
    getAdminUserConversations(user.user_id)
      .then((res) => active && setRows(res.conversations))
      .catch((e) => active && setError(e instanceof Error ? e.message : "Failed to load conversations"))
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [user.user_id]);

  return (
    <div className="mx-auto max-w-4xl animate-fade-in">
      <button
        type="button"
        onClick={onBack}
        className="mb-4 inline-flex items-center gap-1.5 text-sm text-muted transition-colors hover:text-fg"
      >
        <ArrowLeft className="h-4 w-4" aria-hidden />
        All users
      </button>

      <div className="mb-5 flex items-center gap-3">
        <Avatar id={user.user_id} name={label} size="md" />
        <div className="min-w-0">
          <h2 className="truncate text-lg font-semibold text-fg">{label}</h2>
          <p className="text-xs text-muted">Conversations · who they&apos;ve chatted with</p>
        </div>
      </div>

      {error && <Card className="mb-4 border-danger/40 p-4 text-sm text-danger">{error}</Card>}

      {loading ? (
        <Centered>
          <Loader2 className="h-5 w-5 animate-spin" aria-hidden /> Loading conversations…
        </Centered>
      ) : (
        <Card className="divide-y divide-border/50 p-0">
          {rows.map((c) => {
            const title = convLabel(c);
            const subtitle =
              c.type === "direct"
                ? `Direct · ${c.message_count ?? 0} messages`
                : `Group · ${c.participant_count ?? 0} participants`;
            return (
              <button
                key={c.conversation_id}
                type="button"
                onClick={() => onOpen(c)}
                className="flex w-full items-center gap-3 px-3 py-2.5 text-left transition-colors hover:bg-elevated"
              >
                <Avatar id={c.conversation_id} name={title} size="md" />
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium text-fg">{title}</p>
                  <p className="truncate text-xs text-muted">{subtitle}</p>
                </div>
                <span className="shrink-0 text-[11px] tabular-nums text-faint">
                  {listTime(c.last_activity)}
                </span>
              </button>
            );
          })}
          {rows.length === 0 && (
            <div className="p-8 text-center text-sm text-muted">No conversations.</div>
          )}
        </Card>
      )}
    </div>
  );
}

// --- Level 3: a conversation's messages (full for content.read / masked otherwise; audited) --------
function MessagesView({
  user,
  conv,
  onBack
}: {
  user: AdminUser;
  conv: AdminUserConversation;
  onBack: () => void;
}) {
  const [data, setData] = useState<AdminConversationMessages | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const userName = userLabel(user) || shortId(user.user_id);
  const title = convLabel(conv);

  useEffect(() => {
    let active = true;
    setLoading(true);
    setError("");
    getAdminConversationMessages(conv.conversation_id)
      .then((d) => active && setData(d))
      .catch((e) => active && setError(e instanceof Error ? e.message : "Failed to load messages"))
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [conv.conversation_id]);

  return (
    <div className="mx-auto max-w-3xl animate-fade-in">
      <button
        type="button"
        onClick={onBack}
        className="mb-3 inline-flex items-center gap-1.5 text-sm text-muted transition-colors hover:text-fg"
      >
        <ArrowLeft className="h-4 w-4" aria-hidden />
        {userName}&apos;s conversations
      </button>

      {/* Breadcrumb: user › chat */}
      <p className="mb-4 flex items-center gap-1 text-xs text-faint">
        <span>{userName}</span>
        <ChevronRight className="h-3 w-3" aria-hidden />
        <span className="text-muted">{title}</span>
      </p>

      <div className="mb-5 flex items-center gap-3">
        <Avatar id={conv.conversation_id} name={title} size="md" />
        <div className="min-w-0">
          <h2 className="truncate text-lg font-semibold text-fg">{title}</h2>
          <p className="text-xs capitalize text-muted">
            {conv.type} · {conv.message_count ?? 0} messages
          </p>
        </div>
      </div>

      {loading ? (
        <Centered>
          <Loader2 className="h-5 w-5 animate-spin" aria-hidden /> Loading messages…
        </Centered>
      ) : error ? (
        <Card className="border-danger/40 p-4 text-sm text-danger">{error}</Card>
      ) : data ? (
        <>
          <div
            className={cn(
              "mb-4 flex items-center gap-2 rounded-lg border px-3 py-2 text-sm",
              data.masked
                ? "border-border bg-elevated text-muted"
                : "border-success/40 bg-success/10 text-success"
            )}
          >
            {data.masked ? (
              <Lock className="h-4 w-4 shrink-0" aria-hidden />
            ) : (
              <Unlock className="h-4 w-4 shrink-0" aria-hidden />
            )}
            {data.masked
              ? "Masked — you lack content.read; showing metadata only."
              : "Full content — content.read (this access was audited)."}
            <span className="ml-auto shrink-0 text-xs text-faint">{data.message_count} messages</span>
          </div>

          <Card className="divide-y divide-border/60 p-0">
            {data.messages.map((m) => (
              <div key={m.message_id} className="p-3">
                <div className="mb-1 flex items-center gap-2 text-xs text-faint">
                  <span className="font-medium text-muted">{shortId(m.sender_user_id)}</span>
                  {m.message_type ? <span>{m.message_type}</span> : null}
                  <span className="ml-auto tabular-nums">{fmt(m.created_at)}</span>
                </div>
                {data.masked ? (
                  <p className="text-sm italic text-faint">
                    {m.content ?? "[content hidden]"}
                    {m.content_length ? ` · ${m.content_length} chars` : ""}
                  </p>
                ) : m.body || m.content ? (
                  <p className="whitespace-pre-wrap break-words text-sm text-fg">
                    {m.body || m.content}
                  </p>
                ) : (
                  <p className="text-sm text-faint">— (no text — media/system message)</p>
                )}
              </div>
            ))}
            {data.messages.length === 0 && (
              <div className="p-6 text-center text-sm text-muted">No messages.</div>
            )}
          </Card>
        </>
      ) : null}
    </div>
  );
}
