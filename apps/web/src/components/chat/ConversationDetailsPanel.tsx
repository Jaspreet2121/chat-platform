import { useEffect, useMemo, useState } from "react";
import {
  CalendarDays,
  ChevronDown,
  ChevronRight,
  Eraser,
  FileText,
  Phone,
  Image as ImageIcon,
  Link2,
  Play,
  BellOff,
  Star,
  Timer,
  Users,
  X
} from "lucide-react";
import type { AutoDeleteMode, ConversationDetail, Message, MuteMode } from "@/lib/api";
import {
  clearConversation,
  getMediaDownloadUrl,
  getPeerContact,
  listConversationMedia,
  listStarred,
  setConversationAutoDelete,
  setConversationMute
} from "@/lib/api";
import { Avatar, IconButton } from "@/components";
import { cn } from "@/lib/cn";
import { PublicProfileCard } from "./PublicProfileCard";
import { formatTime, metadataString } from "./format";
import { useUserProfile } from "./useUserProfile";

export type ConversationDetailsPanelProps = {
  conversation: ConversationDetail | null;
  conversationId: string;
  title: string;
  isOpen: boolean;
  onClose: () => void;
  /** user_ids currently present in this conversation (have it open). */
  onlineUserIds?: string[];
  /** The viewer's own user id (to mark "You" in a profile / find the direct-chat peer). */
  currentUserId?: string;
  /** The conversation's loaded timeline — source for the media/links strip (recent items only). */
  messages?: Message[];
  /** Jump the main pane to a message (same mechanism as search/starred). Optional: strip stays display-only without it. */
  onJumpToMessage?: (conversationId: string, messageId: string) => void;
  /** Called after a successful "clear chat" so the page refetches this user's (now-empty) timeline. */
  onCleared?: () => void;
};

function shortId(id: string): string {
  return `#${id.slice(0, 8)}`;
}

function formatDate(iso?: string | null): string | null {
  if (!iso) return null;
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return null;
  return date.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

const URL_PATTERN = /https?:\/\/[^\s<>"')\]]+/i;

// How many recent items the strip/list shows — this is loaded-history only, presented as "recent".
const MAX_STRIP_ITEMS = 12;
const MAX_STARRED_PREVIEW = 5;

type MediaItem = {
  message: Message;
  kind: "image" | "video" | "file";
  objectKey: string | null;
  label: string;
};

type LinkItem = { message: Message; url: string; host: string };

// Server gallery item → the strip's MediaItem shape (so MediaThumb + its lazy presign are reused).
function toMediaItem(message: Message): MediaItem {
  const contentType = metadataString(message.metadata, "content_type") ?? "";
  const kind = contentType.startsWith("image/")
    ? "image"
    : contentType.startsWith("video/")
      ? "video"
      : "file";
  return {
    message,
    kind,
    objectKey: metadataString(message.metadata, "object_key"),
    label:
      metadataString(message.metadata, "filename") ||
      (kind === "video" ? "Video" : kind === "image" ? "Photo" : "File")
  };
}

export function ConversationDetailsPanel({
  conversation,
  conversationId,
  title,
  isOpen,
  onClose,
  onlineUserIds = [],
  currentUserId,
  messages = [],
  onJumpToMessage,
  onCleared
}: ConversationDetailsPanelProps) {
  const [profileUserId, setProfileUserId] = useState<string | null>(null);
  const [starred, setStarred] = useState<Message[] | null>(null);
  const [starredOpen, setStarredOpen] = useState(false);
  // Message-visibility actions (user-scoped soft-hides — server-side; per-session display state).
  // Direct-peer contact (phone) — server-verified: only returns for the DM's other participant.
  const [peerPhone, setPeerPhone] = useState<string | null>(null);
  // Shared-media gallery (server query; the viewer's clear/auto-delete window applies).
  const [gallery, setGallery] = useState<Message[] | null>(null);
  const [galleryCursor, setGalleryCursor] = useState<string | null>(null);
  const [galleryLoading, setGalleryLoading] = useState(false);
  const [confirmClear, setConfirmClear] = useState(false);
  const [isClearing, setIsClearing] = useState(false);
  const [autoDelete, setAutoDelete] = useState<AutoDeleteMode | null>(null);
  const [isSavingAutoDelete, setIsSavingAutoDelete] = useState(false);
  // Notification mute (per-conversation; suppresses web-push). Unknown until the user sets it — the
  // control reflects the last choice made this session (server state isn't surfaced in the panel yet).
  const [mute, setMute] = useState<MuteMode>("off");
  const [isSavingMute, setIsSavingMute] = useState(false);
  const [actionError, setActionError] = useState("");

  // Reset transient state when the panel closes or the conversation changes.
  // (Visibility-action state resets in the same effect below via the shared deps.)
  useEffect(() => {
    if (!isOpen) {
      setProfileUserId(null);
      setStarredOpen(false);
      setConfirmClear(false);
      setActionError("");
    }
  }, [isOpen]);

  // Starred-in-this-chat: the EXISTING /api/v1/starred endpoint, filtered client-side by this
  // conversation. Best-effort — on failure the section simply hides (no empty boxes).
  useEffect(() => {
    if (!isOpen || !conversationId) return;
    let active = true;
    setStarred(null);
    listStarred()
      .then((res) => {
        if (!active) return;
        setStarred((res.messages ?? []).filter((m) => m.conversation_id === conversationId));
      })
      .catch(() => {
        if (active) setStarred([]);
      });
    return () => {
      active = false;
    };
  }, [isOpen, conversationId]);

  // Fetch the first shared-media page whenever the panel opens (fresh per conversation).
  useEffect(() => {
    if (!isOpen || !conversationId) return;
    let active = true;
    // Reset deferred (timer) so no setState runs synchronously in the effect body. Mute is
    // per-conversation, so reset its local reflection here too (same conversationId dependency).
    const reset = setTimeout(() => {
      if (active) {
        setGallery(null);
        setGalleryCursor(null);
        setMute("off");
      }
    }, 0);
    listConversationMedia(conversationId, { limit: 18 })
      .then((page) => {
        if (!active) return;
        setGallery(page.items ?? []);
        setGalleryCursor(page.next_cursor ?? null);
      })
      .catch(() => {
        if (active) setGallery([]);
      });
    return () => {
      active = false;
      clearTimeout(reset);
    };
  }, [isOpen, conversationId]);

  const type = conversation?.type ?? "conversation";
  const isDirect = type === "direct";
  const participants = useMemo(() => conversation?.participants ?? [], [conversation?.participants]);
  const createdBy = conversation?.created_by;
  // The participant list is only meaningful for GROUP chats. A direct (1:1) chat's hero already names
  // the other person, so the list is noise — hide it (also covers a stray >2-participant direct row).
  const showParticipants = type === "group" || participants.length > 2;
  const online = new Set(onlineUserIds);
  const selectedRole = participants.find((p) => p.user_id === profileUserId)?.role;

  // The direct-chat peer (the participant who is NOT the viewer) + their live public profile — the
  // hero's name/avatar/about. Reuses the same cached profile hook the rest of the app uses.
  const peer = isDirect ? participants.find((p) => p.user_id !== currentUserId) : undefined;
  const peerProfile = useUserProfile(peer?.user_id ?? null);
  const peerOnline = Boolean(peer && online.has(peer.user_id));
  const heroBio = isDirect ? peerProfile?.bio?.trim() || null : null;

  // Direct-peer phone: fetched only for a DM (the endpoint 403s for anyone but the verified peer).
  const peerUserId = peer?.user_id ?? null;
  useEffect(() => {
    if (!isOpen || !isDirect || !peerUserId || !conversationId) return;
    let active = true;
    const reset = setTimeout(() => {
      if (active) setPeerPhone(null);
    }, 0);
    getPeerContact(peerUserId, conversationId)
      .then((contact) => {
        if (active) setPeerPhone(contact.phone_number ?? null);
      })
      .catch(() => {
        if (active) setPeerPhone(null);
      });
    return () => {
      active = false;
      clearTimeout(reset);
    };
  }, [isOpen, isDirect, peerUserId, conversationId]);

  // Recent links from the ALREADY-LOADED timeline (media moved to the server-backed gallery above).
  const linkItems = useMemo(() => {
    const links: LinkItem[] = [];
    for (const message of messages) {
      if (message.deleted_at || message.media_id || !message.body) continue;
      const match = message.body.match(URL_PATTERN);
      if (!match) continue;
      let host = "";
      try {
        host = new URL(match[0]).hostname.replace(/^www\./, "");
      } catch {
        host = match[0];
      }
      links.push({ message, url: match[0], host });
    }
    links.reverse();
    return links.slice(0, MAX_STRIP_ITEMS);
  }, [messages]);

  if (!isOpen) return null;

  const starredCount = starred?.length ?? 0;
  // Member since: for a direct chat, the peer's joined_at; for a group, the viewer's own row.
  const memberSince = isDirect
    ? formatDate(peer?.joined_at)
    : formatDate(participants.find((p) => p.user_id === currentUserId)?.joined_at);
  const viewerRole = !isDirect
    ? participants.find((p) => p.user_id === currentUserId)?.role
    : undefined;

  function jump(message: Message) {
    if (!onJumpToMessage) return;
    onClose();
    onJumpToMessage(message.conversation_id, message.message_id);
  }

  return (
    <div className="fixed inset-0 z-30 flex justify-end">
      {/* Backdrop */}
      <button
        type="button"
        aria-label="Close details"
        onClick={onClose}
        className="absolute inset-0 bg-black/50 backdrop-blur-sm animate-fade-in"
      />

      {/* Drawer — full-screen on mobile, fixed-width glass panel on desktop */}
      <aside className="relative flex h-full w-full flex-col border-l border-border/70 bg-surface/80 shadow-elevated backdrop-blur-xl animate-slide-in-right sm:w-96">
        <header className="flex items-center justify-between border-b border-border px-4 py-3">
          <h3 className="text-sm font-semibold text-fg">{isDirect ? "Contact info" : "Group info"}</h3>
          <IconButton label="Close details" variant="ghost" onClick={onClose} type="button">
            <X className="h-5 w-5" aria-hidden />
          </IconButton>
        </header>

        <div className="flex-1 overflow-y-auto">
          {/* HERO — large avatar on a soft brand glow, name, presence, about. The one bold moment;
              everything below stays quiet. */}
          <div className="relative border-b border-border px-6 pb-7 pt-8 text-center">
            <div
              aria-hidden
              className="pointer-events-none absolute inset-x-0 top-0 h-36 bg-gradient-to-b from-brand-subtle/50 to-transparent"
            />
            <div className="relative flex flex-col items-center gap-3">
              {isDirect && peer ? (
                <Avatar
                  id={peer.user_id}
                  name={peerProfile?.display_name ?? title}
                  imageUrl={peerProfile?.avatar_url}
                  size="lg"
                  className="h-28 w-28 text-3xl shadow-elevated ring-4 ring-surface/80"
                />
              ) : (
                <Avatar
                  id={conversationId}
                  name={title}
                  size="lg"
                  className="h-28 w-28 text-3xl shadow-elevated ring-4 ring-surface/80"
                />
              )}
              <div className="min-w-0">
                <p className="truncate text-xl font-semibold text-fg">{title}</p>
                {isDirect ? (
                  peerOnline ? (
                    <p className="mt-1 inline-flex items-center gap-1.5 text-xs font-medium text-success">
                      <span aria-hidden className="h-1.5 w-1.5 rounded-full bg-success" />
                      online
                    </p>
                  ) : null
                ) : (
                  <p className="mt-1 text-xs text-muted">
                    Group · {participants.length} participant{participants.length === 1 ? "" : "s"}
                  </p>
                )}
                {heroBio ? <p className="mx-auto mt-2 max-w-64 text-sm text-muted">{heroBio}</p> : null}
                {isDirect && peerPhone ? (
                  <p className="mt-2 inline-flex items-center gap-1.5 text-sm font-medium text-brand-hover">
                    <Phone className="h-3.5 w-3.5" aria-hidden />
                    {peerPhone}
                  </p>
                ) : null}
              </div>
            </div>
          </div>

          {/* SECTION — Shared media (SERVER gallery: the conversation's full media history, newest
              first, paginated; thumbnails presign lazily like chat bubbles). Hidden when empty. */}
          {gallery && gallery.length > 0 ? (
            <div className="border-b border-border py-2">
              <div className="flex min-h-11 w-full items-center gap-3 px-5 py-2 text-left">
                <ImageIcon className="h-4 w-4 shrink-0 text-muted" aria-hidden />
                <span className="min-w-0 flex-1">
                  <span className="block text-sm font-medium text-fg">Shared media</span>
                </span>
                <span className="text-sm tabular-nums text-muted">
                  {gallery.length}
                  {galleryCursor ? "+" : ""}
                </span>
              </div>

              <div className="grid grid-cols-4 gap-1.5 px-5 pb-2 pt-1 sm:grid-cols-4" role="list" aria-label="Shared media">
                {gallery.map((message) => (
                  <GalleryThumb
                    key={message.message_id}
                    item={toMediaItem(message)}
                    onJump={onJumpToMessage ? jump : undefined}
                  />
                ))}
              </div>

              {galleryCursor ? (
                <div className="px-5 pb-3">
                  <button
                    type="button"
                    disabled={galleryLoading}
                    onClick={() => {
                      if (!galleryCursor) return;
                      setGalleryLoading(true);
                      listConversationMedia(conversationId, { before: galleryCursor, limit: 24 })
                        .then((page) => {
                          setGallery((current) => [...(current ?? []), ...(page.items ?? [])]);
                          setGalleryCursor(page.next_cursor ?? null);
                        })
                        .catch(() => undefined)
                        .finally(() => setGalleryLoading(false));
                    }}
                    className="w-full rounded-xl bg-brand-subtle py-2 text-xs font-medium text-brand-hover transition-colors hover:bg-brand-subtle/70 disabled:opacity-50"
                  >
                    {galleryLoading ? "Loading…" : "Show more"}
                  </button>
                </div>
              ) : null}
            </div>
          ) : null}

          {/* SECTION — Links (recent, from the loaded timeline). Hidden when empty. */}
          {linkItems.length > 0 ? (
            <div className="border-b border-border py-2">
              <div className="flex min-h-11 w-full items-center gap-3 px-5 py-2 text-left">
                <Link2 className="h-4 w-4 shrink-0 text-muted" aria-hidden />
                <span className="min-w-0 flex-1">
                  <span className="block text-sm font-medium text-fg">Links</span>
                  <span className="block text-[11px] text-faint">Recent · from loaded messages</span>
                </span>
                <span className="text-sm tabular-nums text-muted">{linkItems.length}</span>
                <ChevronRight className="h-4 w-4 text-faint" aria-hidden />
              </div>

              <div className="flex gap-2 overflow-x-auto px-5 pb-3 pt-1" role="list" aria-label="Recent links">
                {linkItems.map((item) => (
                  <button
                    key={item.message.message_id}
                    type="button"
                    role="listitem"
                    onClick={() => jump(item.message)}
                    title={item.url}
                    className="flex h-20 w-24 shrink-0 flex-col items-center justify-center gap-1.5 rounded-xl border border-border bg-elevated px-2 transition-colors hover:bg-border/60 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-ring"
                  >
                    <Link2 className="h-5 w-5 text-brand-hover" aria-hidden />
                    <span className="w-full truncate text-center text-[11px] text-muted">{item.host}</span>
                  </button>
                ))}
              </div>
            </div>
          ) : null}

          {/* SECTION — Starred messages in this chat (existing /api/v1/starred, filtered). Hidden when 0. */}
          {starredCount > 0 ? (
            <div className="border-b border-border py-2">
              <button
                type="button"
                onClick={() => setStarredOpen((v) => !v)}
                aria-expanded={starredOpen}
                className="flex min-h-11 w-full items-center gap-3 px-5 py-2 text-left transition-colors hover:bg-elevated focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-ring"
              >
                <Star className="h-4 w-4 shrink-0 text-muted" aria-hidden />
                <span className="flex-1 text-sm font-medium text-fg">Starred messages</span>
                <span className="text-sm tabular-nums text-muted">{starredCount}</span>
                {starredOpen ? (
                  <ChevronDown className="h-4 w-4 text-faint" aria-hidden />
                ) : (
                  <ChevronRight className="h-4 w-4 text-faint" aria-hidden />
                )}
              </button>

              {starredOpen ? (
                <ul className="px-5 pb-3">
                  {(starred ?? []).slice(0, MAX_STARRED_PREVIEW).map((message) => (
                    <li key={message.message_id}>
                      <button
                        type="button"
                        onClick={() => jump(message)}
                        className="flex min-h-11 w-full items-center gap-2.5 rounded-xl px-2 py-1.5 text-left transition-colors hover:bg-elevated focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-ring"
                      >
                        <span className="min-w-0 flex-1">
                          <span className="block truncate text-xs text-fg">
                            {message.body?.trim() || message.caption?.trim() || (message.media_id ? "Media" : "Message")}
                          </span>
                          <span className="block text-[11px] text-faint">{formatTime(message.created_at)}</span>
                        </span>
                        <ChevronRight className="h-3.5 w-3.5 shrink-0 text-faint" aria-hidden />
                      </button>
                    </li>
                  ))}
                </ul>
              ) : null}
            </div>
          ) : null}

          {/* SECTION — message visibility (user-scoped: affects ONLY this account's view; the other
              participants keep their copy). Clear = hide everything so far; auto-delete = rolling window. */}
          <div className="border-b border-border px-5 py-3">
            <div className="flex min-h-11 items-center gap-3 py-1">
              <BellOff className="h-4 w-4 shrink-0 text-muted" aria-hidden />
              <span className="flex-1 text-sm text-muted">Mute notifications</span>
              <div className="flex gap-1" role="radiogroup" aria-label="Mute notifications">
                {(["off", "8h", "1w", "always"] as const).map((mode) => (
                  <button
                    key={mode}
                    type="button"
                    role="radio"
                    aria-checked={mute === mode}
                    disabled={isSavingMute}
                    onClick={() => {
                      setActionError("");
                      setIsSavingMute(true);
                      setConversationMute(conversationId, mode)
                        .then(() => setMute(mode))
                        .catch((e) =>
                          setActionError(e instanceof Error ? e.message : "Could not update.")
                        )
                        .finally(() => setIsSavingMute(false));
                    }}
                    className={cn(
                      "rounded-full px-2.5 py-1 text-xs transition-all duration-150",
                      "outline-none focus-visible:ring-2 focus-visible:ring-brand-ring disabled:opacity-50",
                      mute === mode
                        ? "accent-gradient font-medium text-white shadow-accent-glow"
                        : "bg-elevated text-muted hover:text-fg"
                    )}
                  >
                    {mode === "off" ? "Off" : mode === "8h" ? "8h" : mode === "1w" ? "1 week" : "Always"}
                  </button>
                ))}
              </div>
            </div>

            <div className="flex min-h-11 items-center gap-3 py-1">
              <Timer className="h-4 w-4 shrink-0 text-muted" aria-hidden />
              <span className="flex-1 text-sm text-muted">Auto-delete messages</span>
              <div className="flex gap-1" role="radiogroup" aria-label="Auto-delete messages">
                {(["off", "24h", "7d"] as const).map((mode) => (
                  <button
                    key={mode}
                    type="button"
                    role="radio"
                    aria-checked={autoDelete === mode}
                    disabled={isSavingAutoDelete}
                    onClick={() => {
                      setActionError("");
                      setIsSavingAutoDelete(true);
                      setConversationAutoDelete(conversationId, mode)
                        .then(() => setAutoDelete(mode))
                        .catch((e) =>
                          setActionError(e instanceof Error ? e.message : "Could not update.")
                        )
                        .finally(() => setIsSavingAutoDelete(false));
                    }}
                    className={cn(
                      "rounded-full px-2.5 py-1 text-xs transition-all duration-150",
                      "outline-none focus-visible:ring-2 focus-visible:ring-brand-ring disabled:opacity-50",
                      autoDelete === mode
                        ? "accent-gradient font-medium text-white shadow-accent-glow"
                        : "bg-elevated text-muted hover:text-fg"
                    )}
                  >
                    {mode === "off" ? "Off" : mode === "24h" ? "24 hours" : "7 days"}
                  </button>
                ))}
              </div>
            </div>

            {confirmClear ? (
              <div className="mt-1 rounded-xl border border-danger/30 bg-danger/5 p-3">
                <p className="text-sm text-fg">
                  Clear this chat for you? Messages stay for the other participant and can&apos;t be
                  recovered by you.
                </p>
                <div className="mt-2 flex gap-2">
                  <button
                    type="button"
                    disabled={isClearing}
                    onClick={() => {
                      setActionError("");
                      setIsClearing(true);
                      clearConversation(conversationId)
                        .then(() => {
                          setConfirmClear(false);
                          onCleared?.();
                        })
                        .catch((e) =>
                          setActionError(e instanceof Error ? e.message : "Could not clear.")
                        )
                        .finally(() => setIsClearing(false));
                    }}
                    className="rounded-lg bg-danger px-3 py-1.5 text-xs font-medium text-white transition-opacity hover:opacity-90 disabled:opacity-50"
                  >
                    {isClearing ? "Clearing…" : "Clear chat"}
                  </button>
                  <button
                    type="button"
                    disabled={isClearing}
                    onClick={() => setConfirmClear(false)}
                    className="rounded-lg bg-elevated px-3 py-1.5 text-xs font-medium text-muted transition-colors hover:text-fg"
                  >
                    Cancel
                  </button>
                </div>
              </div>
            ) : (
              <button
                type="button"
                onClick={() => setConfirmClear(true)}
                className="flex min-h-11 w-full items-center gap-3 py-1 text-left transition-colors hover:text-danger focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-ring"
              >
                <Eraser className="h-4 w-4 shrink-0 text-danger" aria-hidden />
                <span className="text-sm font-medium text-danger">Clear chat</span>
              </button>
            )}

            {actionError ? <p className="pt-1 text-xs text-danger">{actionError}</p> : null}
          </div>

          {/* SECTION — quiet detail rows. Hidden entirely when nothing is known. */}
          {memberSince || viewerRole ? (
            <div className="border-b border-border px-5 py-3">
              {memberSince ? (
                <div className="flex min-h-11 items-center gap-3 py-1">
                  <CalendarDays className="h-4 w-4 shrink-0 text-muted" aria-hidden />
                  <span className="text-sm text-muted">
                    {isDirect ? "Member since" : "You joined"}{" "}
                    <span className="font-medium text-fg">{memberSince}</span>
                  </span>
                </div>
              ) : null}
              {viewerRole ? (
                <div className="flex min-h-11 items-center gap-3 py-1">
                  <Users className="h-4 w-4 shrink-0 text-muted" aria-hidden />
                  <span className="text-sm capitalize text-muted">
                    Your role · <span className="font-medium text-fg">{viewerRole}</span>
                  </span>
                </div>
              ) : null}
            </div>
          ) : null}

          {/* SECTION — Participants (group chats only). */}
          {showParticipants ? (
            <div className="px-4 py-4">
              <div className="mb-2 flex items-center gap-2 px-1 text-xs font-medium uppercase tracking-wide text-faint">
                <Users className="h-3.5 w-3.5" aria-hidden />
                {participants.length > 0
                  ? `${participants.length} participant${participants.length === 1 ? "" : "s"}`
                  : "Participants"}
              </div>

              {participants.length > 0 ? (
                <ul className="space-y-1">
                  {participants.map((participant) => {
                    const isOnline = online.has(participant.user_id);
                    return (
                      <li key={participant.user_id}>
                        <button
                          type="button"
                          onClick={() => setProfileUserId(participant.user_id)}
                          title="View profile"
                          className="flex w-full items-center gap-3 rounded-xl px-2.5 py-2 text-left transition-colors hover:bg-elevated"
                        >
                          <ParticipantAvatar userId={participant.user_id} online={isOnline} />
                          <div className="min-w-0 flex-1">
                            <p className="truncate text-sm font-medium text-fg">
                              {shortId(participant.user_id)}
                            </p>
                            <p
                              className={cn(
                                "truncate text-xs capitalize",
                                isOnline ? "text-success" : "text-faint"
                              )}
                            >
                              {isOnline ? "online" : participant.role}
                            </p>
                          </div>
                          {createdBy && participant.user_id === createdBy ? (
                            <span className="rounded-full bg-brand-subtle/60 px-2 py-0.5 text-[11px] font-medium text-brand-hover">
                              owner
                            </span>
                          ) : null}
                        </button>
                      </li>
                    );
                  })}
                </ul>
              ) : (
                <p className="px-1 text-sm text-muted">
                  Participant details aren&apos;t available for this conversation yet.
                </p>
              )}
            </div>
          ) : null}
        </div>
      </aside>

      {profileUserId ? (
        <PublicProfileCard
          userId={profileUserId}
          role={selectedRole}
          online={online.has(profileUserId)}
          isSelf={profileUserId === currentUserId}
          onClose={() => setProfileUserId(null)}
        />
      ) : null}
    </div>
  );
}

// A participant's avatar that resolves their real image (cached) with an initials fallback. A separate
// component so the cached profile hook can run per participant (hooks can't be called inside a .map).
function ParticipantAvatar({ userId, online }: { userId: string; online: boolean }) {
  const profile = useUserProfile(userId);
  return (
    <Avatar
      id={userId}
      name={profile?.display_name ?? undefined}
      imageUrl={profile?.avatar_url}
      size="sm"
      online={online}
    />
  );
}

// One tile in the media strip. Images resolve their signed URL (same flow as MessageBubble) and render
// as a true thumbnail; video/file render as quiet typed tiles — no heavy media loads in a strip.
// Grid tile for the shared-media gallery — same lazy presign as the strip thumb, square + fluid.
function GalleryThumb(props: { item: MediaItem; onJump?: (message: Message) => void }) {
  return <MediaThumb {...props} square />;
}

function MediaThumb({
  item,
  onJump,
  square
}: {
  item: MediaItem;
  onJump?: (message: Message) => void;
  square?: boolean;
}) {
  const [url, setUrl] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);
  const { message, kind, objectKey, label } = item;

  useEffect(() => {
    if (kind !== "image" || !message.media_id || !objectKey) return;
    let active = true;
    getMediaDownloadUrl(message.media_id, objectKey)
      .then((res) => {
        if (active) setUrl(res.download_url);
      })
      .catch(() => {
        if (active) setFailed(true);
      });
    return () => {
      active = false;
    };
  }, [kind, message.media_id, objectKey]);

  const clickable = Boolean(onJump);
  const content =
    kind === "image" && url && !failed ? (
      <img
        src={url}
        alt={label === "File" ? "Photo" : label}
        loading="lazy"
        onError={() => setFailed(true)}
        className="h-full w-full object-cover"
      />
    ) : (
      <span className="flex h-full w-full flex-col items-center justify-center gap-1 px-1.5">
        {kind === "video" ? (
          <Play className="h-5 w-5 text-brand-hover" aria-hidden />
        ) : kind === "image" ? (
          <ImageIcon className="h-5 w-5 text-brand-hover" aria-hidden />
        ) : (
          <FileText className="h-5 w-5 text-brand-hover" aria-hidden />
        )}
        <span className="w-full truncate text-center text-[10px] text-muted">{label}</span>
      </span>
    );

  return (
    <button
      type="button"
      role="listitem"
      onClick={clickable ? () => onJump?.(message) : undefined}
      title={clickable ? "Show in chat" : label}
      tabIndex={clickable ? 0 : -1}
      className={cn(
        "shrink-0 overflow-hidden rounded-xl border border-border bg-elevated transition-colors",
        square ? "aspect-square w-full" : "h-20 w-20",
        clickable && "hover:bg-border/60 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-ring"
      )}
    >
      {content}
    </button>
  );
}
